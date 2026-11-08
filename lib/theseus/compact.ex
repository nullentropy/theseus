defmodule Theseus.Compact do
  @moduledoc """
  Compacts the ledger so it stops growing with age. The leader does it while
  the app runs: on its own when the ledger passes a size (config
  `:compaction`, see below), with `Theseus.compact/1`, or with
  `mix theseus.compact`, which also works on a ledger no app has open.

  Every event stays, with its sequence number, id, time, actor and branch,
  so every fold over the ledger (branches, merges, changes, crash
  signatures, consolidation) gives the same result as before. What shrinks:

    * Versions. Each module keeps its last `keep` recorded versions whole,
      and on every branch its current version and the `keep - 1` before
      it. Versions that merges and pending changes start from stay whole
      too. Older versions keep their hash and parent and lose their code.
      Beams stay only for each branch's current versions and the ones
      before them; the loader compiles the others again when it needs them.
    * Decided changes. A change promoted or rejected more than `days` ago
      loses its candidates' code, and each check in its report keeps a
      short summary instead of its evidence. Pending changes, and changes
      decided within `days`, stay whole.

  Nothing is lost: what a run takes out, each record it changes as it was
  and each beam it drops, is added to the archive, which boot never reads:
  the table `_theseus_ledger_archive` (`pos`, `payload`, `archived_at`)
  beside the ledger in Postgres, or a file per run, `<ledger>.archive-<time>`,
  in the ledger's format. In Postgres the changed rows keep their positions. The
  compacted ledger is read back and checked before it is kept, and ends
  with a `:ledger_compacted` event that says what went.

  Config `:compaction`: `auto` (default true), `above_mb` (8) and
  `check_minutes` (60). Every `check_minutes` the leader compacts, with
  the default `keep` and `days`, when the ledger is over `above_mb` and a
  quarter larger than the last compaction left it. `archive_days` (default
  unset: kept for good) makes each run delete what the archive got more than
  that many days before.
  """

  alias Theseus.{Branches, Change, Event, Ledger, LedgerLock, Report, Version}

  @defaults [keep: 5, days: 30]

  @doc """
  Compacts the ledger: the running one when this node runs the app (on a
  follower, the leader does it), otherwise the one at `path`, or in the
  database when the engine keeps its records there. Options: `:keep`
  (versions per module, default 5), `:days` (days of change detail,
  default 30), `:dry_run` (count what would go, change nothing) and `:now`.
  """
  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(path, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)

    with :ok <- check_options(opts) do
      cond do
        Theseus.Leader.standby?() ->
          {:error,
           "this node is a standby: it runs nothing until it holds the ledger's lock. " <>
             "Compact on the node that runs the app."}

        running_here?(path) ->
          Ledger.compact(opts)

        Theseus.Records.database?() ->
          run_db(opts)

        true ->
          run_file(Path.expand(path), opts)
      end
    end
  end

  @doc "The defaults and the automatic compaction's settings."
  @spec settings() :: keyword()
  def settings do
    Keyword.merge(
      @defaults ++ [auto: true, above_mb: 8, check_minutes: 60, archive_days: nil],
      Application.get_env(:theseus, :compaction, [])
    )
  end

  defp running_here?(path) do
    Process.whereis(Ledger) != nil and
      (Theseus.Records.database?() or Path.expand(Ledger.path()) == Path.expand(path))
  end

  defp run_file(path, opts) do
    with :ok <- check_file(path),
         :ok <- LedgerLock.acquire(path) do
      try do
        with {:ok, rows} <- Ledger.file_rows(path) do
          case plan(rows, opts, File.stat!(path).size, path) do
            {:none, stats} -> {:ok, stats}
            {:plan, plan} -> with :ok <- apply_file(path, plan), do: {:ok, done(plan, path)}
          end
          |> finish({:file, path}, opts)
        end
      after
        LedgerLock.release(path)
      end
    end
  end

  # The ledger in Postgres with no node running it.
  defp run_db(opts) do
    alias Theseus.Ledger.Postgres

    with {:ok, db} <- Postgres.standalone() do
      try do
        rows = Postgres.rows_from(db, 0)

        case plan(rows, opts, Postgres.size(db), "the database (#{db.prefix})") do
          {:none, stats} ->
            {:ok, stats}

          {:plan, plan} ->
            with :ok <- Postgres.apply_compaction(db, plan),
                 do: {:ok, %{done(plan, nil) | after_bytes: Postgres.size(db)}}
        end
        |> finish({:db, db}, opts)
      after
        Postgres.release(db)
      end
    end
  end

  @doc false
  # What compacting `rows` (`[{place, payload}]`, in order: a row's
  # position, or any increasing number for a file) would do: `{:none,
  # stats}` when nothing changes or on a dry run, or `{:plan, plan}`.
  #
  # A plan holds the records as read (`records`), each record of the
  # compacted ledger with its payload (`compacted`, the compaction event
  # last), the rows it changes (`changed`, `[{place, old, new}]`), the beams
  # it drops (`dropped`, `[{place, old, key}]`), and the stats.
  def plan(rows, opts, before_bytes, where) do
    opts = Keyword.merge(@defaults, opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    raw = for {place, payload} <- rows, do: {place, payload, :erlang.binary_to_term(payload)}
    records = Ledger.records_from_payloads(for {_, payload} <- rows, do: payload)
    cutoff = DateTime.add(now, -opts[:days] * 86_400, :second)
    {compacted, stats} = compact(records, opts[:keep], cutoff)

    stats =
      Map.merge(stats, %{
        path: where,
        keep: opts[:keep],
        days: opts[:days],
        before_bytes: before_bytes,
        after_bytes: file_size(compacted),
        archive: nil,
        dry_run: Keyword.get(opts, :dry_run, false)
      })

    if stats.records_changed == 0 or stats.dry_run do
      {:none, stats}
    else
      stats = %{stats | archive: archive_name(where, now)}
      event = compaction_event(compacted, stats, now, Keyword.get(opts, :actor, :human))
      full = compacted ++ [{{:event, event}, nil}]
      payloads = Ledger.encode_records(full)
      {kept, [event_payload]} = Enum.split(payloads, -1)
      {changed, dropped} = align(raw, Enum.zip(compacted, kept), [], [])

      next =
        case rows do
          [] -> 0
          _ -> elem(List.last(rows), 0) + 1
        end

      {:plan,
       %{
         stats: stats,
         records: records,
         compacted: Enum.zip(Enum.map(full, &elem(&1, 0)), payloads),
         changed: changed,
         dropped: dropped,
         event: {next, event_payload},
         # Takes the records read back, as `Theseus.Ledger.read_file/1` gives them.
         check: &verify(records, &1)
       }}
    end
  end

  # The compacted records are the records read, less the dropped beams.
  defp align([], [], changed, dropped), do: {Enum.reverse(changed), Enum.reverse(dropped)}

  defp align(
         [{place, old, record} | rest],
         [{{kept, _}, new} | more] = compacted,
         changed,
         dropped
       ) do
    if same_record?(record, kept) do
      changed = if new == old, do: changed, else: [{place, old, new} | changed]
      align(rest, more, changed, dropped)
    else
      {:blob, key, _} = record
      align(rest, compacted, changed, [{place, old, key} | dropped])
    end
  end

  defp align([{place, old, {:blob, key, _}} | rest], [], changed, dropped),
    do: align(rest, [], changed, [{place, old, key} | dropped])

  defp same_record?({:blob, key, _}, {:blob, key, _}), do: true
  defp same_record?({:event, %Event{seq: seq}}, {:event, %Event{seq: seq}}), do: true
  defp same_record?(_a, _b), do: false

  defp archive_name("the database" <> _, _now), do: "_theseus_ledger_archive"
  defp archive_name(path, now), do: path <> ".archive-" <> stamp(now)

  defp stamp(at), do: Calendar.strftime(at, "%Y%m%dT%H%M%SZ")

  @doc false
  # After a run that wrote, or found nothing to do: what the archive got
  # more than `archive_days` ago is deleted, counted in `archive_pruned`.
  def finish({:ok, stats}, target, opts) do
    days = settings()[:archive_days]

    pruned =
      if stats.dry_run or days == nil do
        0
      else
        now = Keyword.get(opts, :now, DateTime.utc_now())
        prune(target, DateTime.add(now, -days * 86_400, :second))
      end

    {:ok, Map.put(stats, :archive_pruned, pruned)}
  end

  def finish(error, _target, _opts), do: error

  defp prune({:db, db}, cutoff), do: Theseus.Ledger.Postgres.prune_archive(db, cutoff)

  defp prune({:file, path}, cutoff) do
    old =
      for file <- Path.wildcard(path <> ".archive-*"),
          at = archived_at(file),
          at != nil and DateTime.compare(at, cutoff) == :lt,
          do: file

    Enum.each(old, &File.rm!/1)
    length(old)
  end

  defp archived_at(file) do
    with [_, y, mo, d, h, mi, s] <-
           Regex.run(~r/\.archive-(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z$/, file),
         [y, mo, d, h, mi, s] = Enum.map([y, mo, d, h, mi, s], &String.to_integer/1),
         {:ok, at} <- NaiveDateTime.new(y, mo, d, h, mi, s) do
      DateTime.from_naive!(at, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp done(plan, path) do
    stats = plan.stats
    if path, do: %{stats | after_bytes: File.stat!(path).size}, else: stats
  end

  @doc false
  # Writes a planned compaction of a file ledger: the old records it takes
  # out to the archive, then the new file beside the old one, checked, and
  # renamed over it.
  def apply_file(path, plan) do
    tmp = path <> ".compacting"
    File.rm(tmp)

    result =
      with :ok <- write(tmp, plan.compacted),
           {:ok, written} <- Ledger.read_file(tmp),
           :ok <- plan.check.(written),
           :ok <- archive(plan.stats.archive, plan),
           do: rename(tmp, path)

    if result != :ok, do: File.rm(tmp)
    result
  end

  defp archive(file, plan) do
    old =
      for({_place, old, _} <- plan.changed, do: old) ++
        for({_place, old, _} <- plan.dropped, do: old)

    Ledger.append_file(file, old)
  rescue
    e -> {:error, "could not write #{file}: #{Exception.message(e)}"}
  end

  defp check_options(opts) do
    cond do
      not (is_integer(opts[:keep]) and opts[:keep] >= 1) ->
        {:error, "--keep must be 1 or more"}

      not (is_integer(opts[:days]) and opts[:days] >= 0) ->
        {:error, "--days must be 0 or more"}

      true ->
        :ok
    end
  end

  defp check_file(path) do
    if File.regular?(path), do: :ok, else: {:error, "no ledger at #{path}"}
  end

  defp write(path, records) do
    Ledger.write_payloads(path, for({_record, payload} <- records, do: payload))
  rescue
    e -> {:error, "could not write #{path}: #{Exception.message(e)}"}
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not rename #{from}: #{:file.format_error(reason)}"}
    end
  end

  defp compaction_event(records, stats, now, actor) do
    seq = Enum.reduce(records, 0, fn {record, _}, acc -> max(acc, seq_of(record)) end) + 1

    %Event{
      seq: seq,
      id: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false),
      at: now,
      actor: actor,
      unit: nil,
      branch: Branches.main(),
      body:
        {:ledger_compacted,
         Map.take(stats, [
           :keep,
           :days,
           :archive,
           :before_bytes,
           :after_bytes,
           :versions_compacted,
           :beams_dropped,
           :changes_compacted
         ])}
    }
  end

  defp seq_of({:event, %Event{seq: seq}}), do: seq
  defp seq_of(_blob), do: 0

  defp file_size(records),
    do: Enum.reduce(records, byte_size("THESEUS1"), fn r, acc -> acc + 8 + payload_size(r) end)

  defp payload_size({_record, payload}) when is_binary(payload), do: byte_size(payload)

  defp payload_size({record, nil}),
    do: byte_size(:erlang.term_to_binary(record, [:compressed]))

  ## Deciding what goes

  @doc false
  # The compacted records and counts. Records left as they were keep their
  # stored payload; changed ones carry nil, to be encoded again.
  def compact(records, keep, cutoff) do
    events = for {{:event, %Event{} = e}, _} <- records, do: e
    whole = whole_versions(events, keep)
    beams = beams(events, whole)
    old = old_changes(events, cutoff)

    {kept, counts} =
      Enum.flat_map_reduce(records, %{}, fn record, counts ->
        case slim(record, whole, beams, old) do
          :keep -> {[record], counts}
          :drop -> {[], bump(counts, :beams_dropped)}
          {what, new} -> {[{new, nil}], bump(counts, what)}
        end
      end)

    stats = %{
      versions_compacted: Map.get(counts, :versions_compacted, 0),
      beams_dropped: Map.get(counts, :beams_dropped, 0),
      changes_compacted: Map.get(counts, :changes_compacted, 0),
      reports_compacted: Map.get(counts, :reports_compacted, 0),
      records_changed: counts |> Map.values() |> Enum.sum(),
      versions_whole: MapSet.size(whole),
      changes_kept_whole: length(changes_in(events)) - MapSet.size(old)
    }

    {kept, stats}
  end

  defp bump(counts, key), do: Map.update(counts, key, 1, &(&1 + 1))

  defp slim({{:blob, key, _beam}, _payload}, _whole, beams, _old),
    do: if(MapSet.member?(beams, key), do: :keep, else: :drop)

  defp slim({{:event, %Event{body: body} = event}, _payload}, whole, _beams, old) do
    case slim_body(body, whole, old) do
      nil -> :keep
      {what, body} -> {what, {:event, %{event | body: body}}}
    end
  end

  defp slim_body({:version_recorded, %Version{unit: m, hash: h} = v}, whole, _old) do
    if MapSet.member?(whole, {m, h}) or Version.compacted?(v),
      do: nil,
      else: {:versions_compacted, {:version_recorded, without_code(v)}}
  end

  defp slim_body({:change_proposed, %Change{id: id} = change}, _whole, old) do
    if MapSet.member?(old, id) and not Change.compacted?(change),
      do:
        {:changes_compacted,
         {:change_proposed, %{change | candidates: Enum.map(change.candidates, &without_code/1)}}},
      else: nil
  end

  defp slim_body({:validated, id, %Report{stages: stages} = report}, _whole, old) do
    if MapSet.member?(old, id) and not Enum.all?(stages, &summary?/1),
      do:
        {:reports_compacted, {:validated, id, %{report | stages: Enum.map(stages, &summarise/1)}}},
      else: nil
  end

  defp slim_body({kind, id, %{name: _} = stage}, _whole, old)
       when kind in [:rules_checked, :shadowed] do
    if MapSet.member?(old, id) and not summary?(stage),
      do: {:reports_compacted, {kind, id, summarise(stage)}},
      else: nil
  end

  defp slim_body(_body, _whole, _old), do: nil

  defp without_code(%Version{} = v), do: %{v | ast: nil, source: nil, beam: nil}

  defp summary?(%{detail: {:summary, _}}), do: true
  defp summary?(_stage), do: false

  # A check keeps the first lines people read about it.
  defp summarise(stage) do
    lines =
      try do
        Theseus.Describe.stage(stage).lines
      rescue
        _ -> []
      end

    %{stage | detail: {:summary, lines |> Enum.take(3) |> Enum.map(&String.slice(&1, 0, 300))}}
  end

  # {module, hash} of every version kept whole.
  defp whole_versions(events, keep) do
    recorded = for %Event{body: {:version_recorded, %Version{} = v}} <- events, do: v
    parents = Map.new(recorded, &{{&1.unit, &1.hash}, &1.parent})

    latest =
      recorded
      |> Enum.reverse()
      |> Enum.uniq_by(&{&1.unit, &1.hash})
      |> Enum.group_by(& &1.unit, & &1.hash)
      |> Enum.flat_map(fn {m, hashes} -> hashes |> Enum.take(keep) |> Enum.map(&{m, &1}) end)

    chains = for {m, h} <- currents(events), key <- chain(parents, m, h, keep), do: key

    decided = decisions(events)

    pending =
      for %Change{id: id} = change <- changes_in(events),
          not Map.has_key?(decided, id),
          v <- change.candidates,
          hash <- [v.parent, v.hash],
          hash != nil,
          do: {v.unit, hash}

    MapSet.new(latest ++ chains ++ merge_bases(events) ++ pending)
  end

  defp chain(_parents, _m, nil, _n), do: []
  defp chain(_parents, _m, _h, 0), do: []
  defp chain(parents, m, h, n), do: [{m, h} | chain(parents, m, parents[{m, h}], n - 1)]

  # Beams for each branch's current versions and the ones before them.
  defp beams(events, whole) do
    recorded =
      for %Event{body: {:version_recorded, %Version{} = v}} <- events, into: %{} do
        {{v.unit, v.hash}, v.parent}
      end

    for {m, h} <- currents(events),
        hash <- [h, recorded[{m, h}]],
        hash != nil,
        MapSet.member?(whole, {m, hash}),
        into: MapSet.new(),
        do: {m, hash}
  end

  defp currents(events) do
    for branch <- branch_names(events),
        unit <- Branches.units_in(events, branch),
        unit.current_version != nil,
        do: {unit.module, unit.current_version}
  end

  defp merge_bases(events) do
    for %Event{body: {:branch_created, child, parent, _}} <- events,
        {module, {child_base, parent_base}} <- Branches.bases_in(events, child, parent),
        hash <- [child_base, parent_base],
        hash != nil,
        do: {module, hash}
  end

  defp branch_names(events) do
    [Branches.main() | for(%Event{body: {:branch_created, name, _, _}} <- events, do: name)]
  end

  defp changes_in(events),
    do: for(%Event{body: {:change_proposed, %Change{} = c}} <- events, do: c)

  # Change ids decided before the cutoff.
  defp old_changes(events, cutoff) do
    for {id, at} <- decisions(events), DateTime.compare(at, cutoff) == :lt, into: MapSet.new() do
      id
    end
  end

  # When each decided change was last decided (as `Theseus.Changes` replays).
  defp decisions(events) do
    Enum.reduce(events, %{}, fn
      %Event{body: {:gate_decision, id, :promote, _}, at: at}, acc ->
        Map.put(acc, id, at)

      %Event{body: {:rejected, id, _}, at: at}, acc ->
        Map.put(acc, id, at)

      %Event{body: {:promoted, _, _, _, id}, at: at}, acc when is_binary(id) ->
        Map.put(acc, id, at)

      _event, acc ->
        acc
    end)
  end

  ## Checking the new file

  # The new file reads back, every event is still there in order, and every
  # branch folds to the same units and merge bases, with whole current
  # versions and their beams.
  defp verify(records, written) do
    old = for {{:event, e}, _} <- records, do: e
    new = for {{:event, e}, _} <- written, do: e
    new_events = Enum.drop(new, -1)
    had_beam = blob_keys(records)
    has_beam = blob_keys(written)

    had_version =
      MapSet.new(for %Event{body: {:version_recorded, v}} <- old, do: {v.unit, v.hash})

    versions =
      for %Event{body: {:version_recorded, %Version{} = v}} <- new, into: %{} do
        {{v.unit, v.hash}, v}
      end

    checks = [
      {"every event is kept", length(old) == length(new_events)},
      {"events keep their order and identity",
       Enum.zip(old, new_events) |> Enum.all?(fn {a, b} -> same_event?(a, b) end)},
      {"every branch has the same units",
       Enum.all?(branch_names(old), fn b ->
         Branches.units_in(old, b) == Branches.units_in(new, b)
       end)},
      {"every branch has the same merge bases",
       Enum.all?(for(%Event{body: {:branch_created, c, p, _}} <- old, do: {c, p}), fn {c, p} ->
         Branches.bases_in(old, c, p) == Branches.bases_in(new, c, p)
       end)},
      {"current versions are whole, with their beams",
       Enum.all?(currents(new), fn {_m, h} = key ->
         case versions[key] do
           %Version{ast: ast} = v when ast != nil ->
             Version.hash(ast) == h and not Version.compacted?(v) and
               (MapSet.member?(has_beam, key) or not MapSet.member?(had_beam, key))

           nil ->
             not MapSet.member?(had_version, key)

           _compacted ->
             false
         end
       end)}
    ]

    case for({what, false} <- checks, do: what) do
      [] -> :ok
      failed -> {:error, "the compacted ledger failed checks: " <> Enum.join(failed, ", ")}
    end
  end

  defp blob_keys(records),
    do: for({{:blob, key, beam}, _} <- records, is_binary(beam), into: MapSet.new(), do: key)

  defp same_event?(%Event{body: a} = old, %Event{body: b} = new) do
    Map.drop(old, [:body]) == Map.drop(new, [:body]) and same_body?(a, b)
  end

  defp same_body?(a, a), do: true

  defp same_body?({:version_recorded, a}, {:version_recorded, b}),
    do: {a.unit, a.hash, a.parent} == {b.unit, b.hash, b.parent}

  defp same_body?({:change_proposed, a}, {:change_proposed, b}) do
    ids = fn c -> Enum.map(c.candidates, &{&1.unit, &1.hash, &1.parent}) end
    %{a | candidates: nil} == %{b | candidates: nil} and ids.(a) == ids.(b)
  end

  defp same_body?({:validated, id, a}, {:validated, id, b}) do
    a.passed == b.passed and a.change_id == b.change_id and
      Enum.map(a.stages, &{&1.name, &1.result}) == Enum.map(b.stages, &{&1.name, &1.result})
  end

  defp same_body?({kind, id, a}, {kind, id, b}) when kind in [:rules_checked, :shadowed],
    do: {a.name, a.result} == {b.name, b.result}

  defp same_body?(_a, _b), do: false

  ## Reporting

  @doc "A compaction result as lines for a person."
  @spec report(map()) :: String.t()
  def report(%{records_changed: 0} = s),
    do:
      "Nothing to compact in #{s.path} (#{kb(s.before_bytes)}). Everything older than the " <>
        "last #{s.keep} versions and #{s.days} days is compacted already."

  def report(s) do
    head =
      if s.dry_run,
        do:
          "Dry run: #{s.path} would go from #{kb(s.before_bytes)} to about #{kb(s.after_bytes)}.",
        else: "Compacted #{s.path} from #{kb(s.before_bytes)} to #{kb(s.after_bytes)}."

    {lose, drop, stay} =
      if s.dry_run,
        do: {"would lose", "would be dropped", "would stay"},
        else: {"lost", "were dropped", "stay"}

    [
      head,
      "  #{s.versions_compacted} older versions #{lose} their code (#{s.versions_whole} #{stay} whole: " <>
        "the last #{s.keep} per module and every version in use).",
      "  #{s.beams_dropped} beams #{drop}; a rollback compiles them again.",
      "  #{s.changes_compacted} changes decided more than #{s.days} days ago #{lose} their code " <>
        "and #{s.reports_compacted} reports their evidence; #{s.changes_kept_whole} changes #{stay} whole.",
      if(s.archive, do: "  What went is kept in #{s.archive}, which boot does not read."),
      if(Map.get(s, :archive_pruned, 0) > 0,
        do: "  #{s.archive_pruned} archived entries older than the archive's days were deleted."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp kb(bytes), do: "#{div(bytes + 1023, 1024)} KB"
end
