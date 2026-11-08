defmodule Theseus.CompactTest do
  @moduledoc "Compaction keeps every event and every version in use, and shrinks the rest."

  use ExUnit.Case, async: false

  alias Theseus.{Branches, Change, Compact, Describe, Event, Ledger, Report, Unit, Version}

  @module Demo.CompactPrice
  @old ~U[2026-01-01 00:00:00Z]
  @recent ~U[2026-02-25 00:00:00Z]
  @now ~U[2026-03-01 00:00:00Z]

  setup do
    dir = Path.expand("../../tmp/compact_test_#{System.unique_integer([:positive])}", __DIR__)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "app.theseus")
    versions = build_ledger(path)
    %{path: path, dir: dir, v: versions}
  end

  # main: v1 -> v7, one change per version; changes for v2..v5 decided long
  # ago, v6 and v7 recently. Branch feature forks at v3 and has a pending
  # change on top of it.
  defp build_ledger(path, beams \\ :fake) do
    versions =
      Enum.reduce(1..8, %{}, fn n, acc ->
        parent = if n == 8, do: acc[3].hash, else: acc[n - 1] && acc[n - 1].hash
        source = "defmodule #{inspect(@module)} do\n  def price, do: #{n}\nend\n"
        {:ok, v} = Version.build(@module, source, parent)

        beam =
          case beams do
            :fake -> "beam #{n}"
            :real -> with {:ok, beam} <- Theseus.Loader.compile(v), do: beam
          end

        Map.put(acc, n, %{v | beam: beam})
      end)

    unit = %Unit{module: @module, current_version: versions[1].hash}

    records =
      recorded(versions[1], @old) ++
        [{:unit_registered, unit, @old}] ++
        Enum.flat_map(2..7, fn n ->
          at = if n <= 5, do: @old, else: @recent
          id = "chg_#{n}"

          [
            {:change_proposed, change(id, versions[n], "main"), at},
            {:validated, id, report(id), at},
            {:gate_decision, id, :promote, :human, at}
          ] ++
            recorded(versions[n], at) ++
            [{:promoted, @module, versions[n - 1].hash, versions[n].hash, id, at}] ++
            if n == 3,
              do: [
                {:branch_created, "feature", "main",
                 [%{unit | current_version: versions[3].hash}], at}
              ],
              else: []
        end) ++
        [
          {:change_proposed, change("chg_pending", versions[8], "feature"), @recent},
          {:validated, "chg_pending", report("chg_pending"), @recent}
        ]

    {records, _seq} =
      Enum.map_reduce(records, 0, fn
        {:blob, key, beam}, seq ->
          {{{:blob, key, beam}, nil}, seq}

        tuple, seq ->
          at = elem(tuple, tuple_size(tuple) - 1)
          body = Tuple.delete_at(tuple, tuple_size(tuple) - 1)

          branch =
            if match?({:branch_created, _, _, _}, body) or pending?(body),
              do: "feature",
              else: "main"

          event = %Event{
            seq: seq + 1,
            id: "evt#{seq + 1}",
            at: at,
            actor: :human,
            unit: @module,
            branch: branch,
            body: body
          }

          {{{:event, event}, nil}, seq + 1}
      end)

    :ok = Ledger.write_file(path, records)
    versions
  end

  defp pending?({_kind, %Change{id: "chg_pending"}}), do: true
  defp pending?({:validated, "chg_pending", _}), do: true
  defp pending?(_body), do: false

  defp recorded(%Version{unit: m, hash: h, beam: beam} = v, at),
    do: [{:blob, {m, h}, beam}, {:version_recorded, %{v | beam: nil}, at}]

  defp change(id, version, branch) do
    %Change{
      id: id,
      trigger: %{kind: :human, payload: nil, untrusted: false},
      proposer: %{kind: :mcp, client: "test"},
      intent: "set the price",
      unit: @module,
      candidates: [%{version | beam: nil}],
      branch: branch,
      at: @old
    }
  end

  defp report(id) do
    %Report{
      change_id: id,
      passed: true,
      stages: [
        %{name: :static, result: :pass, detail: %{}, ms: 1},
        %{
          name: :replay,
          result: :pass,
          detail: %{compared: 12, differ: 0, evidence: String.duplicate("x", 5000)},
          ms: 9
        }
      ]
    }
  end

  defp events(path) do
    {:ok, records} = Ledger.read_file(path)
    for {{:event, e}, _} <- records, do: e
  end

  defp blobs(path) do
    {:ok, records} = Ledger.read_file(path)
    for {{:blob, key, _}, _} <- records, into: MapSet.new(), do: key
  end

  defp recorded_version(events, hash),
    do:
      Enum.find_value(events, fn
        %Event{body: {:version_recorded, %Version{hash: ^hash} = v}} -> v
        _ -> nil
      end)

  defp proposed(events, id),
    do:
      Enum.find_value(events, fn
        %Event{body: {:change_proposed, %Change{id: ^id} = c}} -> c
        _ -> nil
      end)

  defp validated(events, id),
    do:
      Enum.find_value(events, fn
        %Event{body: {:validated, ^id, report}} -> report
        _ -> nil
      end)

  test "keeps every event and every version in use, and removes the rest", %{path: path, v: v} do
    before = events(path)
    File.cp!(path, path <> ".original")

    assert {:ok, stats} = Compact.run(path, keep: 2, days: 30, now: @now)
    assert stats.archive == path <> ".archive-20260301T000000Z"
    assert stats.after_bytes < stats.before_bytes

    # The archive holds each record as it was before the run changed or
    # dropped it, the removed code among them.
    assert {:ok, archived} = Ledger.read_file(stats.archive)
    {:ok, originals} = Ledger.read_file(path <> ".original")
    assert Enum.all?(archived, &(&1 in originals))
    archived_events = for {{:event, e}, _} <- archived, do: e

    after_events = events(path)

    # Every event is still there, in order, then one saying what happened.
    assert Enum.map(Enum.drop(after_events, -1), &{&1.seq, &1.id, &1.at}) ==
             Enum.map(before, &{&1.seq, &1.id, &1.at})

    assert %Event{seq: seq, body: {:ledger_compacted, %{keep: 2, days: 30}}} =
             List.last(after_events)

    assert seq == length(before) + 1
    assert Describe.event(List.last(after_events).body) =~ "keeping 2 versions per module"

    for branch <- ["main", "feature"] do
      assert Branches.units_in(after_events, branch) == Branches.units_in(before, branch)
    end

    # Whole: the last two versions (v6, v7), main's current and the one
    # before it (v7, v6), feature's current and the one before it (v3, v2),
    # and the merge base and the pending change's base (v3).
    whole = for n <- [2, 3, 6, 7], do: v[n].hash
    removed = for n <- [1, 4, 5], do: v[n].hash

    for hash <- whole, do: refute(Version.compacted?(recorded_version(after_events, hash)))

    for hash <- removed do
      version = recorded_version(after_events, hash)
      assert Version.compacted?(version) and version.ast == nil
      assert version.parent == recorded_version(before, hash).parent
      assert recorded_version(archived_events, hash).ast != nil
    end

    # Beams stay for each branch's current version and the one before it.
    assert blobs(path) == MapSet.new(for n <- [2, 3, 6, 7], do: {@module, v[n].hash})

    # Changes decided before the cutoff lose their code and keep summaries.
    for n <- 2..5 do
      change = proposed(after_events, "chg_#{n}")
      assert Change.compacted?(change)
      assert [%{unit: @module, hash: hash, parent: parent}] = change.candidates
      assert {hash, parent} == {v[n].hash, v[n - 1].hash}

      report = validated(after_events, "chg_#{n}")
      assert report.passed

      assert [%{name: :static, result: :pass}, %{name: :replay, detail: {:summary, lines}}] =
               report.stages

      assert lines == ["all 12 recorded calls give the same result"]

      d = Describe.change(%{change | status: :promoted}, report)
      assert d.compacted
      assert Enum.find(d.stages, &(&1.name == "replay")).lines == lines
    end

    # Recent and pending changes stay whole.
    for id <- ["chg_6", "chg_7", "chg_pending"] do
      refute Change.compacted?(proposed(after_events, id))
      assert %{detail: %{evidence: _}} = Enum.at(validated(after_events, id).stages, 1)
    end
  end

  test "a version's code is written once, and reads back whole", %{path: path, v: v} do
    <<"THESEUS1", rest::binary>> = File.read!(path)

    raw =
      Stream.unfold(rest, fn
        <<size::32, _crc::32, payload::binary-size(size), more::binary>> ->
          {:erlang.binary_to_term(payload), more}

        _ ->
          nil
      end)
      |> Enum.to_list()

    # Version 2 is proposed, then recorded: the record keeps only a pointer.
    assert [%Version{source: source}] =
             for(
               {:event, %Event{body: {:change_proposed, %Change{id: "chg_2"} = c}}} <- raw,
               do: c.candidates
             )
             |> List.flatten()

    assert is_binary(source)

    assert [%Version{source: :earlier, ast: :earlier}] =
             for(
               {:event, %Event{body: {:version_recorded, %Version{hash: h} = r}}} <- raw,
               h == v[2].hash,
               do: r
             )

    # Reading fills it in.
    assert %Version{source: ^source, ast: ast} = recorded_version(events(path), v[2].hash)
    assert ast == v[2].ast
  end

  test "a second run finds nothing to do", %{path: path, dir: dir} do
    assert {:ok, %{records_changed: n}} = Compact.run(path, keep: 2, days: 30, now: @now)
    assert n > 0
    compacted = File.read!(path)

    assert {:ok, %{records_changed: 0} = stats} = Compact.run(path, keep: 2, days: 30, now: @now)
    assert Compact.report(stats) =~ "Nothing to compact"
    assert File.read!(path) == compacted
    assert length(Path.wildcard(Path.join(dir, "*.archive-*"))) == 1
  end

  test "with archive_days set, a run deletes what the archive got before then", %{path: path} do
    config = Application.get_env(:theseus, :compaction)
    on_exit(fn -> Application.put_env(:theseus, :compaction, config || []) end)

    assert {:ok, %{archive: archive, archive_pruned: 0}} =
             Compact.run(path, keep: 2, days: 30, now: @now)

    Application.put_env(:theseus, :compaction, archive_days: 10)
    assert {:ok, %{archive_pruned: 0}} = Compact.run(path, keep: 2, days: 30, now: @now)
    assert File.exists?(archive)

    later = DateTime.add(@now, 20 * 86_400, :second)
    assert {:ok, %{records_changed: 0} = stats} = Compact.run(path, keep: 2, days: 30, now: later)
    assert stats.archive_pruned == 1
    refute File.exists?(archive)
  end

  test "a dry run counts and changes nothing", %{path: path, dir: dir} do
    original = File.read!(path)

    assert {:ok, stats} = Compact.run(path, keep: 2, days: 30, now: @now, dry_run: true)
    assert stats.versions_compacted == 3 and stats.changes_compacted == 4
    assert Compact.report(stats) =~ "Dry run"
    assert File.read!(path) == original
    assert Path.wildcard(Path.join(dir, "*.archive-*")) == []
    refute File.exists?(path <> ".lock")
  end

  test "with the defaults, a young ledger loses only beams it can compile again", %{path: path} do
    assert {:ok, stats} = Compact.run(path, now: ~U[2026-01-02 00:00:00Z])
    assert %{versions_compacted: 0, changes_compacted: 0, reports_compacted: 0} = stats
    assert stats.beams_dropped == 3
  end

  @tag timeout: 120_000
  test "an app on a compacted ledger boots, rolls back and records removed code again",
       %{dir: dir} do
    path = Path.join(dir, "real.theseus")
    v = build_ledger(path, :real)
    # keep 3: v4 loses its code; v1 and v5 stay whole without beams.
    assert {:ok, %{versions_compacted: 1}} = Compact.run(path, keep: 3, days: 30, now: @now)
    refute MapSet.member?(blobs(path), {@module, v[5].hash})

    peer = start_peer(path)
    call = fn m, f, a -> :peer.call(peer, m, f, a, 60_000) end

    assert call.(@module, :price, []) == 7

    # v6 has its beam; v5 is compiled again and its beam stored.
    assert {:ok, _} = call.(Theseus, :rollback, [@module, v[6].hash])
    assert {:ok, _} = call.(Theseus, :rollback, [@module, v[5].hash])
    assert call.(@module, :price, []) == 5
    assert {:ok, %Version{beam: beam}} = call.(Ledger, :version, [@module, v[5].hash])
    assert is_binary(beam)

    assert {:error, message} = call.(Theseus, :rollback, [@module, v[4].hash])
    assert message =~ "removed when the ledger was compacted"

    # The same code proposed again is recorded whole, and listed once.
    assert {:ok, :recorded} = call.(Ledger, :put_version, [v[4], [actor: :system]])
    assert {:ok, %Version{ast: ast}} = call.(Ledger, :version, [@module, v[4].hash])
    assert ast != nil
    hashes = for version <- call.(Ledger, :versions_for, [@module]), do: version.hash
    assert Enum.count(hashes, &(&1 == v[4].hash)) == 1
  end

  @tag timeout: 120_000
  test "a running app compacts its ledger in place and carries on", %{dir: dir} do
    path = Path.join(dir, "live.theseus")
    v = build_ledger(path, :real)
    peer = start_peer(path)
    call = fn m, f, a -> :peer.call(peer, m, f, a, 60_000) end
    assert call.(@module, :price, []) == 7

    assert {:ok, stats} = call.(Compact, :run, [path, [keep: 3, days: 30, now: @now]])
    assert stats.versions_compacted == 1
    assert File.exists?(stats.archive)

    # The running app reads the compacted ledger: v4 has no code, v5 no beam.
    assert {:ok, %Version{ast: nil}} = call.(Ledger, :version, [@module, v[4].hash])
    assert {:ok, %Version{beam: nil}} = call.(Ledger, :version, [@module, v[5].hash])
    assert call.(@module, :price, []) == 7

    assert {:ok, _} = call.(Theseus, :rollback, [@module, v[6].hash])
    assert {:ok, _} = call.(Theseus, :rollback, [@module, v[5].hash])
    assert call.(@module, :price, []) == 5

    # Code removed by the run is written whole when it comes back, not as
    # a pointer to a copy that is gone.
    assert {:ok, :recorded} = call.(Ledger, :put_version, [v[4], [actor: :system]])
    assert {:ok, %Version{ast: ast}} = call.(Ledger, :version, [@module, v[4].hash])
    assert ast != nil

    # The file on disk holds the same: a fresh read gives the same events.
    :peer.stop(peer)
    on_disk = events(path)
    v4 = v[4].hash

    assert [_compacted, %Version{ast: ^ast}] =
             for(%Event{body: {:version_recorded, %Version{hash: ^v4} = r}} <- on_disk, do: r)

    assert Enum.any?(on_disk, &match?(%Event{body: {:ledger_compacted, _}}, &1))
  end

  @tag timeout: 120_000
  test "the leader compacts on its own once the ledger is large", %{dir: dir} do
    path = Path.join(dir, "auto.theseus")
    build_ledger(path, :real)
    peer = start_peer(path, compaction: [above_mb: 0, check_minutes: 0.005])

    assert Enum.find_value(1..200, fn _ ->
             Process.sleep(50)

             Enum.find(:peer.call(peer, Ledger, :events, []), fn
               %Event{actor: :system, body: {:ledger_compacted, _}} -> true
               _ -> false
             end)
           end)

    assert :peer.call(peer, @module, :price, []) == 7
  end

  defp start_peer(path, extra \\ []) do
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: Enum.flat_map(:code.get_path() -- [~c"."], &[~c"-pa", &1]) ++ [~c"-noinput"],
        wait_boot: 30_000
      })

    # The node stops with the test process; stop it here if it has not.
    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    env =
      Application.get_all_env(:theseus)
      |> Enum.reject(fn {_k, v} -> is_function(v) or is_pid(v) end)
      |> Keyword.merge(
        ledger_path: path,
        branch: "main",
        trace_file: false,
        state_file: false,
        connections_file: false,
        outbox_file: false,
        outbox: [adapter: :hold],
        crash_repair: [enabled: false],
        consolidate: [enabled: false],
        app: [server: false],
        admin: [server: false, port: 0]
      )
      |> Keyword.merge(extra)

    :ok = :peer.call(peer, :logger, :set_primary_config, [:level, :warning])
    :ok = :peer.call(peer, Application, :load, [:theseus])
    for {k, v} <- env, do: :ok = :peer.call(peer, Application, :put_env, [:theseus, k, v])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:theseus], 90_000)
    :ok = :peer.call(peer, Logger, :configure, [[level: :warning]])
    peer
  end

  test "the ledger this app has open is compacted by the app, and bad options are refused",
       %{path: path} do
    assert {:ok, %{dry_run: true}} = Compact.run(Ledger.path(), dry_run: true)
    assert {:error, "--keep must be 1 or more"} = Compact.run(path, keep: 0)
    assert {:error, "no ledger at " <> _} = Compact.run(path <> ".missing")
  end
end
