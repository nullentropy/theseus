defmodule Theseus.Describe do
  @moduledoc """
  Turns changes, reports and ledger events into plain data (strings, numbers,
  lists, maps) for the review page, the MCP tools and iex. Describes
  behaviour and evidence, never source code. Every result is JSON-safe.
  """

  alias Theseus.{Change, Ledger, PageText, Report, Shadow, Signature, Unit, Version}

  @download_lines 300

  @doc "One line about a change."
  def summary(%Change{} = change) do
    %{
      id: change.id,
      unit: inspect(change.unit),
      status: to_string(change.status),
      intent: change.intent,
      proposer: proposer(change.proposer),
      at: DateTime.to_iso8601(change.at),
      touches: touches(change),
      branch: change.branch,
      group_id: change.group,
      trigger:
        case change.trigger.kind do
          :crash -> "crash"
          :consolidate -> "consolidation"
          :merge -> "merge"
          :combined -> "combined"
          _ -> "person"
        end
    }
  end

  @doc "A change with its evidence."
  def change(%Change{} = change, report) do
    summary(change)
    |> Map.merge(%{
      creates: Change.creates?(change),
      removes: Change.removes?(change),
      rationale: change.rationale,
      behaviour_change: change.behaviour_change,
      passed: report != nil and report.passed,
      failed_at:
        with(
          %Report{} <- report,
          %{name: n} <- Report.failure(report),
          do: to_string(n),
          else: (_ -> nil)
        ),
      stages: if(report, do: Enum.map(report.stages, &stage/1), else: []),
      group: group(change),
      behaviour: evidence(report, :behaviour),
      dependents: dependents(report),
      shadow: evidence(report, :shadow),
      shadow_progress: shadow_progress(change),
      spec_changes: spec_changes(report),
      spec_after: spec_after(report),
      crash: crash(change),
      combined: combined(change),
      compacted: Change.compacted?(change),
      schema_changes: schema_changes(change),
      services_changes: services_changes(change),
      held_because: if(change.status == :held, do: hold_reason(change))
    })
  end

  # A change the engine made by combining a stale change with the one
  # approved before it (Theseus.Combine).
  defp combined(%Change{trigger: %{kind: :combined, payload: %{replaces: r, onto: o}}}),
    do: %{replaces: r, onto: o}

  defp combined(_change), do: nil

  # For a crash fix: what crashed, which attempt, and the crash report.
  # The report is data from outside the system.
  defp crash(%Change{trigger: %{kind: :crash, payload: payload}}) do
    %{signature: sig, attempt: attempt, round: round, crash: crash} = payload

    %{
      signature: sig.id,
      what: Signature.describe_short(sig),
      attempt: attempt,
      round: round,
      untrusted_report:
        Enum.join(
          [
            "error: #{text(crash.error)}",
            "call: #{crash.fun}#{call_args(crash.args)}"
          ],
          "\n"
        )
    }
  end

  defp crash(_change), do: nil

  defp hold_reason(%Change{id: id, unit: unit}) do
    reason =
      unit
      |> Ledger.events_for()
      |> Enum.find_value(fn
        %{body: {:gate_decision, ^id, {:hold, reason}, _}} -> reason
        _ -> nil
      end)

    hold_text(reason)
  end

  # The other changes proposed together with this one.
  defp group(%Change{group: nil}), do: nil

  # A group that was only checked is not recorded, so it has no members.
  defp group(%Change{group: group, id: id}) do
    case Theseus.Changes.group(group) do
      [] ->
        nil

      members ->
        %{
          id: group,
          changes:
            for {c, _} <- members do
              %{id: c.id, unit: inspect(c.unit), status: to_string(c.status), this: c.id == id}
            end
        }
    end
  end

  # The units that call the changed units: their specs and recorded calls
  # run against the proposed versions.
  defp dependents(%Report{} = report) do
    case Report.stage(report, :dependents) do
      %{detail: %{units: units}} ->
        for u <- units do
          %{
            unit: inspect(u.unit),
            kind: to_string(u.kind),
            spec?: u.spec?,
            failed: for(f <- u.failed, do: "#{f.name}: #{failure(f.detail)}"),
            calls: u.traces && trace_evidence(u.traces)
          }
        end

      _ ->
        []
    end
  end

  defp dependents(_report), do: []

  @doc "Why the gate held a change, for people."
  def hold_text(:group),
    do: "it is one of several changes made together, which a person approves together"

  def hold_text(:creates_a_unit), do: "it creates a new unit"

  def hold_text(:server_unit),
    do: "it changes a server unit, which holds state, and server units are decided by a person"

  def hold_text(:changes_the_spec),
    do: "it also changes the spec, and only a person changes a spec"

  def hold_text(:not_the_first_attempt), do: "it is not the first attempt at this crash"

  def hold_text(:declares_tables_or_services),
    do: "it changes the app's tables or the outside services it uses, which a person decides"

  def hold_text({:replay, result}), do: "replay did not pass (#{result})"
  def hold_text({:shadow, :skip}), do: "no live calls arrived to try it on"
  def hold_text({:shadow, result}), do: "the shadow run did not pass (#{result})"

  def hold_text({:diff_too_large, n}),
    do: "it changes #{n} lines, more than crash repair may change on its own"

  def hold_text(_reason),
    do: "a person decides every change that is not an automatic crash fix or consolidation"

  @doc "A stage as a name, a result and readable lines."
  def stage(%{name: name, result: result, detail: detail, ms: ms}) do
    %{
      name: to_string(name),
      result: to_string(result),
      ms: ms,
      lines: stage_lines(name, result, detail)
    }
  end

  @doc "A ledger event body as one readable line."
  def event({:rules_checked, id, %{result: result}}),
    do: "the model read the rules of #{id} (#{result})"

  def event({:version_recorded, %Version{unit: m, hash: h, parent: p}}),
    do:
      "recorded #{inspect(m)} version #{Version.short(h)}#{if p, do: " (from #{Version.short(p)})", else: ""}"

  def event({:unit_registered, %Unit{module: m, kind: k, current_version: h}}),
    do: "registered #{inspect(m)} (#{k}) at #{Version.short(h)}"

  def event({:change_proposed, %Change{trigger: %{kind: :crash, payload: p}} = c}),
    do:
      "#{c.id} proposed by #{proposer(c.proposer)} after a crash (signature #{p.signature.id}, " <>
        "attempt #{p.attempt}#{if p.round == 2, do: ", repair round", else: ""}): #{c.intent}"

  def event({:change_proposed, %Change{trigger: %{kind: :consolidate, payload: p}} = c}),
    do:
      "#{c.id} proposed by #{proposer(c.proposer)} to consolidate the unit" <>
        "#{if p.round == 2, do: " (repair round)", else: ""}: #{c.intent}"

  def event({:change_proposed, %Change{trigger: %{kind: :combined, payload: p}} = c}),
    do:
      "#{c.id} proposed by the engine, combining #{Enum.join(p.replaces, ", ")} with #{p.onto}, which changed the same units: #{c.intent}"

  def event({:change_proposed, %Change{trigger: %{kind: :merge, payload: p}} = c}),
    do:
      "#{c.id} proposed by #{proposer(c.proposer)} on #{c.branch}, merging from #{p.from}: #{c.intent}"

  def event({:change_proposed, %Change{} = c}),
    do:
      "#{c.id} proposed by #{proposer(c.proposer)}" <>
        if(c.branch == "main", do: "", else: " on #{c.branch}") <> ": #{c.intent}"

  def event({:validated, id, %Report{passed: true}}), do: "#{id} passed validation"

  def event({:validated, id, %Report{} = r}),
    do: "#{id} failed validation at #{Report.failure(r).name}"

  def event({:gate_decision, id, {:hold, reason}, _by}),
    do: "#{id} held for a person: #{hold_text(reason)}"

  def event({:gate_decision, id, :promote, by}), do: "#{id} approved (#{by})"
  def event({:gate_decision, id, :reject, by}), do: "#{id} rejected (#{by})"

  def event({:promoted, m, from, to, id}),
    do:
      "#{inspect(m)} #{Version.short(from)} -> #{Version.short(to)}#{if id, do: " (#{id})", else: ""}"

  def event({:rolled_back, m, from, to, reason}),
    do: "#{inspect(m)} rolled back #{Version.short(from)} -> #{Version.short(to)}: #{reason}"

  def event({:rejected, id, reason}), do: "#{id} rejected: #{text(reason)}"

  def event({:shadowed, id, stage}),
    do: "#{id} shadow run: " <> Enum.join(stage_lines(:shadow, stage.result, stage.detail), "; ")

  def event({:crash_seen, %Signature{} = s, summary}),
    do: "crashed: #{Signature.describe_short(s)} (signature #{s.id}): #{summary.error}"

  def event({:repair_started, id, attempt}),
    do: "crash repair attempt #{attempt} started for signature #{id}"

  def event({:repair_failed, id, attempt, reason}),
    do: "crash repair attempt #{attempt} for signature #{id} failed: #{text(reason)}"

  def event({:signature_marked, id, :needs_human, reason}),
    do: "signature #{id} needs a person: #{reason}"

  def event({:signature_marked, id, :cleared, reason}), do: "signature #{id}: #{reason}"
  def event({:signature_marked, id, :resolved, reason}), do: "signature #{id}: #{reason}"

  def event({:branch_created, name, from, _units}), do: "branch #{name} created from #{from}"

  def event({:branch_switched, to, from}), do: "the live branch is now #{to} (was #{from})"

  def event({:schema_migrated, m, s}) do
    parts =
      for(t <- s.dropped_tables, do: "dropped table #{t}") ++
        for({t, c} <- s.dropped_columns, do: "dropped #{t}.#{c}") ++
        for({t, c} <- s.required, do: "made #{t}.#{c} required") ++
        for({t, n} <- s.filled, n > 0, do: "backfill/2 set #{n} rows of #{t}")

    "#{inspect(m)} migrated the app's data: " <>
      if(parts == [], do: "nothing to change", else: Enum.join(parts, ", "))
  end

  def event({:branch_described, name, text}), do: "branch #{name} is for: #{text}"
  def event({:branch_closed, name}), do: "branch #{name} closed"
  def event({:branch_reopened, name}), do: "branch #{name} reopened"

  def event({:consolidation_started, unit, base, n}),
    do: "consolidating #{inspect(unit)} at #{Version.short(base)} after #{n} changes"

  def event({:consolidation_failed, unit, reason}),
    do: "consolidating #{inspect(unit)} failed: #{text(reason)}"

  def event({:approval_override, id, reason}), do: "#{id} approved over a rule: #{reason}"

  def event({:group_undone, group, reason}), do: "#{group} undone (#{reason})"

  def event({:unit_unregistered, module, reason}),
    do: "#{inspect(module)} removed: #{reason}"

  def event({:ledger_compacted, c}),
    do:
      "the ledger was compacted from #{kb(c.before_bytes)} to #{kb(c.after_bytes)}, " <>
        "keeping #{c.keep} versions per module and #{c.days} days of change detail " <>
        "(what went is kept in #{c.archive})"

  def event(other), do: inspect(other, limit: 20)

  defp kb(bytes), do: "#{div(bytes + 1023, 1024)} KB"

  @doc """
  A data term as short readable text. Candidate module names are shown as
  the unit's own name.
  """
  def text(term),
    do: term |> raw_text() |> String.replace(~r/Theseus\.Candidate\.[A-Za-z0-9]+\./, "")

  defp raw_text({:candidate_server, _kind, reason}) when is_binary(reason),
    do: "the proposed server unit could not start from the live state: #{reason}"

  defp raw_text({:candidate_server, kind, reason}),
    do:
      "the proposed server unit could not start from the live state (#{kind}: #{inspect(reason, limit: 8)}); its code_change/3 must take the live state"

  defp raw_text({:group_not_ready, waiting}),
    do:
      "not every change of its group is ready to approve: " <>
        Enum.map_join(waiting, ", ", fn {id, status} -> "#{id} is #{status}" end)

  defp raw_text(term) when is_binary(term), do: term

  defp raw_text(%{__exception__: true} = e),
    do: "#{inspect(e.__struct__)}: #{Exception.message(e)}"

  defp raw_text({kind, reason}) when kind in [:throw, :exit] and is_binary(reason),
    do: "#{kind}: #{reason}"

  defp raw_text({kind, reason}) when kind in [:throw, :exit],
    do: "#{kind} #{inspect(reason, limit: 30)}"

  defp raw_text(term), do: inspect(term, limit: 30, printable_limit: 200)

  @doc "A unit's recent ledger entries as readable lines, oldest first."
  def history_lines(unit, limit) do
    for e <- Theseus.Introspect.history(unit, limit),
        do:
          "#{DateTime.to_iso8601(e.at)} #{e.actor}" <>
            if(e.branch == "main", do: "", else: " [#{e.branch}]") <> ": #{event(e.body)}"
  end

  @doc "A recorded call as one line: the call, then its result or error and where it raised."
  def trace_line(%Theseus.Trace{} = t) do
    call = "#{t.fun}(" <> Enum.map_join(t.args, ", ", &inspect(&1, limit: 30)) <> ")"

    case t.result do
      {:ok, value} ->
        "#{call} -> #{inspect(value, limit: 30)}"

      {:error, error, stacktrace} ->
        "#{call} -> raised #{text(error)}#{frames(t.unit, stacktrace)}"
    end
  end

  defp frames(unit, stacktrace) do
    own =
      for {mod, fun, arity, loc} <- stacktrace,
          mod == unit,
          not String.starts_with?(Atom.to_string(fun), "-") do
        "#{fun}/#{if is_list(arity), do: length(arity), else: arity} line #{loc[:line]}"
      end

    if own == [], do: "", else: " at " <> Enum.join(Enum.take(own, 3), ", ")
  end

  defp proposer(%{person: person} = p) when is_binary(person),
    do: "#{person}, through #{proposer(Map.delete(p, :person))}"

  defp proposer(%{kind: kind, client: nil}), do: to_string(kind)
  defp proposer(%{kind: kind, client: client}), do: "#{client} (#{kind})"
  defp proposer(_), do: "unknown"

  defp touches(%Change{removes: removes}) when removes != nil, do: ["removes it"]

  defp touches(change) do
    Enum.map(change.candidates, fn v -> if Unit.spec_name?(v.unit), do: "spec", else: "unit" end)
  end

  defp stage_lines(name, result, %{counts: %{fixed: f, unfixed: u} = c, compared: n})
       when name in [:replay, :shadow] and f + u > 0 do
    where = if name == :replay, do: "recorded", else: "live"
    others = c.changed + c.now_succeed + c.now_fail
    rest = n - f - u

    if result == :pass,
      do: ["#{f} #{where} calls that crashed now work; the other #{rest} give the same result"],
      else: [
        "#{u} of the #{f + u} #{where} calls that crashed still fail, " <>
          "and #{others} of the other #{rest} behave differently"
      ]
  end

  defp stage_lines(:replay, :pass, %{compared: n} = detail),
    do: ["all #{n} recorded calls give the same result" <> on_data(detail)]

  defp stage_lines(:replay, :fail, %{compared: n, differ: d} = detail),
    do: [
      "#{d} of #{n} recorded calls behave differently, " <>
        "but the change says it keeps behaviour the same" <> on_data(detail)
    ]

  defp stage_lines(:replay, :info, %{compared: n, differ: d} = detail),
    do: [
      "#{d} of #{n} recorded calls behave differently; the change is meant to change behaviour" <>
        on_data(detail)
    ]

  defp stage_lines(:shadow, :running, %{calls: calls, ms: ms}),
    do: ["comparing with live calls, up to #{calls} calls or #{seconds(ms)}"]

  defp stage_lines(:shadow, :pass, %{compared: n}),
    do: ["all #{n} live calls gave the same result"]

  defp stage_lines(:shadow, :fail, %{compared: n, differ: d}),
    do: [
      "#{d} of #{n} live calls behaved differently, " <>
        "but the change says it keeps behaviour the same"
    ]

  defp stage_lines(:shadow, :info, %{compared: n, differ: d}),
    do: ["#{d} of #{n} live calls behaved differently; the change is meant to change behaviour"]

  defp stage_lines(:dependents, result, %{units: units} = detail)
       when result in [:pass, :info, :fail] do
    lines =
      for u <- units do
        spec =
          cond do
            not u.spec? ->
              "it has no spec"

            u.failed == [] ->
              "its spec passes"

            true ->
              "its spec fails: " <>
                Enum.map_join(u.failed, "; ", &"#{&1.name}: #{failure(&1.detail)}")
          end

        calls =
          case u.traces do
            %{compared: n, differ: d} = t when n > 0 ->
              ", and #{d} of its #{n} recorded calls behave differently" <>
                styling_note(Map.get(t, :counts, %{}), d)

            _ ->
              ""
          end

        "#{inspect(u.unit)} calls a changed unit: #{spec}#{calls}"
      end

    if detail[:keeps_behaviour],
      do: lines ++ ["the change says it keeps behaviour the same"],
      else: lines
  end

  defp stage_lines(:rules, :info, %{rules: verdicts} = detail) do
    ["#{detail[:model] || "the model"} read the code of each new or changed rule:"] ++
      for v <- verdicts do
        if v.matches,
          do: "#{v.rule}: the code checks this",
          else: "#{v.rule}: the code may not check this: #{v.why}"
      end
  end

  defp stage_lines(:backfill, _result, %{tables: tables}) do
    for t <- tables do
      "#{t.table}: backfill/2 sets #{t.changed} of #{t.rows}#{if t.more, do: "+", else: ""} rows" <>
        Enum.map_join(t.samples, "", fn s -> "; #{s.id}: #{inspect(s.set, limit: 6)}" end) <>
        Enum.map_join(t.unfilled, "", &"; #{&1.rows} rows still have no #{&1.column}") <>
        Enum.map_join(t.errors, "", &"; #{&1}")
    end
  end

  defp stage_lines(_name, :pass, nil), do: []
  defp stage_lines(_name, :pass, %{count: n}), do: ["#{n} passed"]
  defp stage_lines(_name, _result, %{reason: reason}), do: [reason]

  defp stage_lines(:static, :fail, %{violations: by_module}) do
    for {m, list} <- by_module, v <- list, do: "#{inspect(m)}: #{v}"
  end

  defp stage_lines(:compile, :fail, %{errors: by_module}) do
    for {m, reason} <- by_module, do: "#{inspect(m)}: #{compile_error(reason)}"
  end

  defp stage_lines(_name, :fail, %{failed: failed}) do
    for %{name: name, detail: detail} <- failed, do: "#{name}: #{failure(detail)}"
  end

  defp stage_lines(:behaviour, :info, %{created: true}), do: ["creates a new unit"]

  defp stage_lines(:behaviour, :info, %{traces: nil, traces_note: note}) when is_binary(note),
    do: [note]

  defp stage_lines(:behaviour, :info, %{traces: traces}) do
    case traces do
      nil ->
        ["the unit itself does not change"]

      t ->
        c = counts(t)

        fixes =
          if c.fixed + c.unfixed > 0,
            do: ", #{c.fixed} that crashed now work, #{c.unfixed} still crash",
            else: ""

        removed =
          if c.removed > 0,
            do:
              "; #{c.removed} calls to functions the proposed version no longer has were not run",
            else: ""

        dropped =
          case Map.get(t, :dropped_callbacks, []) do
            [] -> ""
            list -> "; it no longer has #{Enum.join(list, " and ")}, which the engine calls"
          end

        [
          "re-ran #{t.compared} recorded calls: #{c.changed} give a different result" <>
            styling_note(c) <>
            ", #{c.now_succeed} now succeed, #{c.now_fail} now fail" <>
            fixes <> removed <> dropped
        ]
    end
  end

  # Compaction keeps a check's first lines and drops its evidence.
  defp stage_lines(_name, _result, {:summary, lines}), do: lines
  defp stage_lines(_name, _result, %{timeout_ms: ms}), do: ["timed out after #{ms} ms"]
  defp stage_lines(_name, _result, %{crashed: text}), do: ["crashed: #{text}"]
  defp stage_lines(_name, _result, %{error: reason}), do: [text(reason)]
  defp stage_lines(_name, _result, detail), do: [text(detail)]

  # Replays on the live branch read the app's data as it is now.
  defp on_data(%{data: :snapshot}), do: " (on the app's data)"
  defp on_data(_detail), do: ""

  defp failure(%{expected: e, got: g}), do: "expected #{text(e)}, got #{text(g)}"
  defp failure(%{expected: e, raised: r}), do: "expected #{text(e)}, raised #{text(r)}"

  defp failure(%{counterexample: %{args: args, got: got}}),
    do: "fails for #{call_args(args)} giving #{text(got)}"

  defp failure(%{counterexample: %{args: args, raised: r}}),
    do: "fails for #{call_args(args)}: raised #{text(r)}"

  defp failure(%{generator: message}), do: "its inputs could not be generated: #{message}"
  defp failure(detail) when detail == %{}, do: "does not hold"

  defp failure(%{raised: text}) when is_binary(text),
    do:
      "does not hold: it raised #{String.replace(text, ~r/Theseus\.Candidate\.[A-Za-z0-9]+\./, "")}"

  defp failure(detail), do: text(detail)

  defp compile_error({:warnings, warnings}),
    do: "the compiler warns: " <> Enum.join(warnings, "; ") <> ". Fix the warnings."

  defp compile_error({:compile, errors}),
    do: Enum.map_join(errors, "; ", fn e -> "#{e.message} (line #{line(e.position)})" end)

  defp compile_error({:seed, why}), do: "its rows do not fit the tables: " <> why
  defp compile_error(other), do: text(other)

  defp line({line, _col}), do: line
  defp line(line), do: line

  defp call_args(args), do: "(" <> Enum.map_join(args, ", ", &inspect(&1, limit: 20)) <> ")"

  # Recorded calls (from the behaviour stage) or live calls (from the shadow
  # run) that behave differently, as rows.
  defp evidence(%Report{} = report, name) do
    detail =
      case Report.stage(report, name) do
        %{name: :behaviour, result: :info, detail: %{traces: t}} -> t
        %{name: :shadow, result: r, detail: %{compared: _} = t} when r != :running -> t
        _ -> nil
      end

    with %{} = t <- detail, do: trace_evidence(t)
  end

  defp evidence(_report, _name), do: nil

  defp trace_evidence(t) do
    %{
      compared: t.compared,
      counts: counts(t),
      changed: Enum.map(t.changed, &row/1),
      now_succeed: Enum.map(t.now_succeed, &row/1),
      now_fail: Enum.map(t.now_fail, &row/1),
      fixed: Enum.map(Map.get(t, :fixed, []), &row/1),
      unfixed: Enum.map(Map.get(t, :unfixed, []), &row/1),
      removed: Enum.map(Map.get(t, :removed, []), &row/1)
    }
  end

  # Phase 1 reports have no counts; their lists were not capped in practice.
  # Phase 2 reports have no fixed or unfixed calls.
  defp counts(%{counts: counts}),
    do: Map.merge(%{fixed: 0, unfixed: 0, removed: 0, styling_only: 0}, counts)

  defp counts(t),
    do: %{
      changed: length(t.changed),
      now_succeed: length(t.now_succeed),
      now_fail: length(t.now_fail),
      fixed: 0,
      unfixed: 0,
      removed: 0,
      styling_only: 0
    }

  @doc false
  # " (N of them only in styling)", or nothing. `of` is how many the note
  # follows: the calls that give a different result unless said otherwise.
  def styling_note(counts, of \\ nil)
  def styling_note(%{styling_only: 0}, _of), do: ""

  def styling_note(%{styling_only: n} = counts, of) do
    if n == (of || Map.get(counts, :changed)),
      do: " (all of them only in styling)",
      else: " (#{n} of them only in styling)"
  end

  def styling_note(_counts, _of), do: ""

  defp shadow_progress(%Change{status: :shadowing, id: id}) do
    with %{} = p <- Shadow.progress(id) do
      %{
        p
        | ends_at: DateTime.to_iso8601(DateTime.truncate(p.ends_at, :second))
      }
      |> Map.put(:seconds_left, max(DateTime.diff(p.ends_at, DateTime.utc_now()), 0))
    end
  end

  defp shadow_progress(_change), do: nil

  defp seconds(ms) when ms < 1000, do: "#{ms} ms"
  defp seconds(ms), do: "#{div(ms, 1000)} s"

  # `before_changed`/`after_changed` show only the fields that differ, when
  # both results are maps.
  defp row(%{fun: fun, args: args, before: before, after: {:error, :removed}}) do
    %{
      call: "#{fun}#{call_args(args)}",
      before: result(before),
      after: "the proposed version has no #{fun}/#{length(args)}",
      before_changed: nil,
      after_changed: nil
    }
  end

  defp row(%{fun: fun, args: args, before: before, after: after_}) do
    {before_changed, after_changed} = changed_fields(before, after_)

    %{
      call: "#{fun}#{call_args(args)}",
      before: result(before),
      after: result(after_),
      before_changed: before_changed,
      after_changed: after_changed
    }
  end

  defp changed_fields({:ok, %{} = b}, {:ok, %{} = a})
       when not is_struct(b) and not is_struct(a) do
    keys =
      (Map.keys(b) ++ Map.keys(a))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(b, &1, :missing) != Map.get(a, &1, :missing)))
      |> Enum.sort()

    fields = fn map ->
      Enum.map_join(keys, ", ", fn k ->
        value = if Map.has_key?(map, k), do: text(map[k]), else: "(none)"
        "#{if is_atom(k), do: k, else: text(k)}: #{value}"
      end)
    end

    if keys == [], do: {nil, nil}, else: {fields.(b), fields.(a)}
  end

  # Two pages: the visible lines only one of them has, or what kind of
  # markup differs (see `Theseus.PageText.compare/2`).
  defp changed_fields({:ok, {s1, :html, b}}, {:ok, {s2, :html, a}})
       when is_binary(b) and is_binary(a),
       do: page_rows("#{s1} page #{page_title(b)}", "#{s2} page #{page_title(a)}", s1 == s2, b, a)

  # HTML a page unit returned, the same way.
  defp changed_fields({:ok, b}, {:ok, a}) when is_binary(b) and is_binary(a) do
    if PageText.html?(b) and PageText.html?(a),
      do: page_rows(result({:ok, b}), result({:ok, a}), true, b, a),
      else: {nil, nil}
  end

  # Two downloads: the lines only one of them has, in order.
  defp changed_fields(
         {:ok, {_, {:download, _, _}, b}} = before,
         {:ok, {_, {:download, _, _}, a}} = after_
       )
       when is_binary(b) and is_binary(a) do
    # A large file is compared on its first lines only, so the page stays fast.
    {b_lines, a_lines} = {String.split(b, "\n"), String.split(a, "\n")}
    cut = max(length(b_lines), length(a_lines)) > @download_lines

    {removed, added} =
      List.myers_difference(
        Enum.take(b_lines, @download_lines),
        Enum.take(a_lines, @download_lines)
      )
      |> Enum.reduce({[], []}, fn
        {:del, lines}, {r, ad} -> {r ++ lines, ad}
        {:ins, lines}, {r, ad} -> {r, ad ++ lines}
        _, acc -> acc
      end)

    note = if cut, do: ["(first #{@download_lines} lines compared)"], else: []

    {Enum.join([result(before) | Enum.take(removed, 6)] ++ note, " | "),
     Enum.join([result(after_) | Enum.take(added, 6)] ++ note, " | ")}
  end

  # Two answers with the same htmx headers: what is inside them.
  defp changed_fields({:ok, {:htmx, headers, b}}, {:ok, {:htmx, headers, a}}),
    do: changed_fields({:ok, b}, {:ok, a})

  defp changed_fields(_before, _after), do: {nil, nil}

  defp page_rows(before_label, after_label, same_status?, b, a) do
    case PageText.compare(b, a) do
      :same ->
        {nil, nil}

      :styling when same_status? ->
        {before_label, after_label <> ": the same page, only styling differs"}

      :markup when same_status? ->
        {before_label,
         after_label <> ": the same visible text; links, forms, scripts or other markup differ"}

      {:text, removed, added} ->
        {Enum.join([before_label | Enum.take(removed, 6)], " | "),
         Enum.join([after_label | Enum.take(added, 6)], " | ")}

      _status_differs ->
        {before_label, after_label}
    end
  end

  # A page shows as its status and title; its text, not its markup, is what
  # a person compares.
  defp result({:ok, {status, :html, html}}) when is_integer(status) and is_binary(html),
    do: "#{status} page #{page_title(html)}"

  defp result({:ok, {status, {:download, name, _type}, data}}) when is_binary(data),
    do: "#{status} download #{inspect(name)} (#{lines_count(data)})"

  # A file the engine keeps, sent back (see `Theseus.Files`).
  defp result({:ok, {status, {:upload, id}}}) when is_integer(status),
    do: "#{status} file #{text(id)}"

  # Messages an endpoint sends (see `Theseus.Outbox`), then its answer.
  defp result({:ok, {:send, messages, inner}}) when is_list(messages),
    do: "#{sends(messages)}, then #{result({:ok, inner})}"

  # Requests to outside services (see `Theseus.Fetch`), then its answer.
  defp result({:ok, {:fetch, requests, inner}}) when is_list(requests),
    do: "#{fetches(requests)}, then #{result({:ok, inner})}"

  # htmx headers an endpoint sets (see `Theseus.Endpoint`), with its answer.
  # Rows an endpoint writes (see `Theseus.Store`), then its answer.
  defp result({:ok, {:write, ops, inner}}) when is_list(ops),
    do: "#{writes(ops)}, then #{result({:ok, inner})}"

  # The engine's own check, so headers it would refuse say so.
  defp result({:ok, {:htmx, headers, inner}}) do
    set =
      case Theseus.Web.htmx_headers(headers) do
        {:ok, pairs} -> "headers " <> Enum.map_join(pairs, ", ", fn {k, v} -> "#{k}: #{v}" end)
        {:error, why} -> "headers the engine refuses: #{why}"
      end

    "#{result({:ok, inner})}, with htmx #{set}"
  end

  defp result({:ok, html}) when is_binary(html) do
    cond do
      not PageText.html?(html) -> text(html)
      title = PageText.title(html) -> "HTML page #{inspect(title)}"
      true -> "HTML starting #{inspect(html |> page_lines() |> List.first() || "")}"
    end
  end

  defp result({:ok, value}), do: text(value)

  defp result({:error, error}), do: "error: " <> text(error)

  defp lines_count(data) do
    n = data |> String.split("\n", trim: true) |> length()
    if n == 1, do: "1 line", else: "#{n} lines"
  end

  defp writes(ops) do
    shown =
      ops
      |> Enum.take(4)
      |> Enum.map_join("; ", fn op ->
        case Theseus.Store.write!(op) do
          {:insert, table, id, row, _} ->
            "inserts #{table} #{id} (#{fields(Map.delete(row, :id))})"

          {:update, table, id, changes, _} ->
            "updates #{table} #{id} (#{fields(changes)})"

          {:delete, table, id, _, _} ->
            "deletes #{table} #{id}"

          {:error, why} ->
            "one the store refuses: #{why}"
        end
      end)

    more = if length(ops) > 4, do: " and #{length(ops) - 4} more", else: ""
    "writes #{length(ops)} #{if length(ops) == 1, do: "row", else: "rows"} (#{shown}#{more})"
  end

  defp fields(map) do
    map |> Enum.sort() |> Enum.take(6) |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{text(v)}" end)
  end

  defp sends(messages) do
    shown =
      messages
      |> Enum.take(3)
      |> Enum.map_join("; ", fn m ->
        # The outbox's own check, so a message it would refuse says so.
        case Theseus.Outbox.normalize(m) do
          {:ok, ok} -> "to #{Enum.join(ok.to, ", ")}: #{inspect(ok.subject)}"
          {:error, why} -> "one the outbox refuses: #{why}"
        end
      end)

    more = if length(messages) > 3, do: " and #{length(messages) - 3} more", else: ""
    noun = if length(messages) == 1, do: "message", else: "messages"
    "sends #{length(messages)} #{noun} (#{shown}#{more})"
  end

  defp fetches(requests) do
    shown =
      requests
      |> Enum.take(3)
      |> Enum.map_join("; ", fn r ->
        case Theseus.Fetch.normalize(r) do
          {:ok, r} ->
            url =
              case Theseus.Fetch.url(r, Theseus.Services.get(r.service)) do
                {:ok, url} -> url
                {:error, why} -> "#{r.url}, which the engine refuses: #{why}"
              end

            for_domain = if r.domain, do: " for #{r.domain}", else: ""
            "#{r.method} #{url} from #{r.service}#{for_domain}"

          {:error, why} ->
            "one the engine refuses: #{why}"
        end
      end)

    more = if length(requests) > 3, do: " and #{length(requests) - 3} more", else: ""
    noun = if length(requests) == 1, do: "request", else: "requests"
    "makes #{length(requests)} #{noun} (#{shown}#{more})"
  end

  defp page_title(html), do: inspect(PageText.title(html) || "")

  defp page_lines(html), do: PageText.lines(html)

  # What a schema unit's candidate adds to the branch's tables.
  defp schema_changes(%Change{candidates: candidates, branch: branch}) do
    for %Version{unit: m, ast: ast} <- candidates,
        ast != nil and Theseus.Schema.schema_unit?(ast),
        {:ok, new} <- [Theseus.Schema.from_ast(ast)],
        old = Map.new(Theseus.Store.DB.schema_units(branch))[m] || %{},
        line <-
          Theseus.Schema.describe_changes(old, new) ++
            Theseus.Schema.describe_drops(old, new) ++ backfill_line(m, ast, branch),
        do: line
  end

  defp backfill_line(module, ast, branch) do
    v = %Version{unit: module, ast: ast, hash: nil, source: nil}

    if Theseus.Store.Migrate.backfill?(v, %{required: []}, branch),
      do: ["runs backfill/2 over every existing row when approved"],
      else: []
  end

  # What a services unit's candidate changes in the outside services the
  # app uses (Theseus.Services).
  defp services_changes(%Change{candidates: candidates, branch: branch}) do
    for %Version{unit: m, ast: ast} <- candidates,
        ast != nil and Theseus.Services.services_unit?(ast),
        {:ok, new} <- [Theseus.Services.from_ast(ast)],
        old = Map.new(Theseus.Services.units(branch))[m] || %{},
        line <- Theseus.Services.describe_changes(old, new),
        do: line
  end

  defp spec_changes(%Report{stages: stages}) do
    case Enum.find(stages, &(&1.name == :behaviour and &1.result == :info)) do
      %{detail: %{spec: spec}} when spec != nil -> spec
      _ -> nil
    end
  end

  defp spec_changes(_), do: nil

  defp spec_after(%Report{stages: stages}) do
    case Enum.find(stages, &(&1.name == :behaviour and &1.result == :info)) do
      %{detail: %{spec_after: spec}} -> spec
      _ -> nil
    end
  end

  defp spec_after(_), do: nil
end
