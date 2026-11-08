defmodule Theseus.Validator do
  @moduledoc """
  Runs a change through its stages and returns a `%Theseus.Report{}`.

  Stages, in order, stopping at the first failure:

    1. `:static`: the static check on every candidate, on the live node. It
       only reads the syntax tree, and runs before anything is compiled.
    2. `:compile`: compile every candidate under a renamed module
       (`Theseus.Candidate.<id>.<Module>`) and load it under that name.
    3. `:examples`, `:properties`, `:invariants`: the spec (the candidate
       spec if the change has one, else the live spec) against the unit (the
       candidate unit if the change has one, else the live unit).
    4. `:behaviour` (report only): what changes compared to the live system.
       See `Theseus.Validator.Behaviour`.
    5. `:replay`: judges the behaviour stage's recorded calls. A change that
       says it keeps behaviour (`behaviour_change: false`) fails if any
       recorded call behaves differently. A crash fix must also make every
       recorded call that failed with its signature succeed. A behaviour
       change only reports.
    6. `:dependents`: every unit that calls the changed units, directly or
       through other units, runs its own spec against the new versions, and
       its recorded calls are replayed through them. A failing spec fails
       the change; differences are reported, and fail a change that keeps
       behaviour.
    7. `:shadow`: the candidate beside the live unit on live calls. It runs
       after the change is recorded (see `Theseus.Shadow`), so here it is
       either `:running` (option `shadow: true` and everything passed) or
       skipped.

  Stages 2 to 6 run on a fresh sandbox node (`Theseus.Sandbox`), with the
  live units and specs loaded there from their stored beams and the replay
  sets copied over. Candidate code never runs on the live node during
  validation. Each stage also runs in its own process with a timeout.
  Specs run against fresh server state; the comparisons (behaviour, replay,
  dependents) start both systems' server units from a copy of the live
  state, migrated with `code_change/3` for a changed server unit.

  The candidate world: on the sandbox, the change's unit, the other units
  of its group (option `:group`, the other changes proposed with it) and
  every unit that calls any of them are compiled under candidate names,
  with their references to each other renamed too. A candidate therefore
  calls the other candidates, and the live units keep calling live units,
  so "before" and "after" are two complete systems. Server units of both
  are started fresh, and again before each comparison.
  """

  require Logger
  alias Theseus.{Branches, Change, Ledger, Report, Sandbox, Shadow, Spec, Traces, Unit, Version}
  alias Theseus.Validator.{Behaviour, Static}

  @stages [
    :static,
    :compile,
    :examples,
    :properties,
    :invariants,
    :behaviour,
    :replay,
    :dependents,
    :shadow
  ]

  @doc "Validates a change and returns its report. See `validate/2`."
  @spec run(Change.t(), keyword()) :: Report.t()
  def run(%Change{} = change, opts \\ []), do: change |> validate(opts) |> elem(0)

  @doc """
  Validates a change. Option `shadow: true` marks the shadow stage to run;
  option `group` lists the other changes proposed together with this one.
  Returns the report and, when the shadow stage is to run, the compiled
  unit candidate as `{module, beam}` for `Theseus.Shadow`.
  """
  @spec validate(Change.t(), keyword()) :: {Report.t(), {module(), binary()} | nil}
  def validate(change, opts \\ [])

  def validate(%Change{removes: removes} = change, opts) when removes != nil,
    do: {removal_report(change, Keyword.get(opts, :group, [])), nil}

  def validate(%Change{} = change, opts) do
    run_id = System.unique_integer([:positive])
    ctx = context(change, Keyword.get(opts, :group, []))

    renamed =
      Map.new(
        change.candidates ++
          ctx.siblings ++ ctx.sibling_specs ++ Enum.map(ctx.carried, & &1.version),
        &{&1.unit, candidate_name(&1, run_id)}
      )

    static = static_stage(change, ctx)

    {stages, beams} =
      if static.result == :fail do
        {[static], %{}}
      else
        started = System.monotonic_time(:millisecond)

        # Sandboxes are shared fairly between the people proposing.
        run = fn ->
          on_snapshot(
            ctx,
            &Sandbox.run(__MODULE__, :run_sandboxed, [change, renamed, &1], sandbox_timeout())
          )
        end

        case Theseus.Queue.run(queue_owner(change), run) do
          {:ok, {stages, beams}} ->
            {[static | stages], beams}

          # :peer.call answers :badarg when the process running the
          # validation dies abnormally.
          {:ok, other} ->
            ms = System.monotonic_time(:millisecond) - started
            reason = "the validation on the sandbox died (#{inspect(other)})"
            {[static, %{name: :compile, result: :fail, detail: %{error: reason}, ms: ms}], %{}}

          {:error, reason} ->
            ms = System.monotonic_time(:millisecond) - started
            {[static, %{name: :compile, result: :fail, detail: %{error: reason}, ms: ms}], %{}}
        end
      end

    stages =
      if Enum.any?(stages, &(&1.result == :fail)),
        do: stages,
        else: stages ++ [shadow_stage(change, ctx, opts)]

    report = %Report{
      change_id: change.id,
      stages: pad_skipped(stages),
      passed: not Enum.any?(stages, &(&1.result == :fail))
    }

    shadow =
      with %{result: :running} <- Report.stage(report, :shadow),
           %Version{unit: unit} <- Change.unit_candidate(change),
           module = renamed[unit],
           beam when is_binary(beam) <- beams[module] do
        {module, beam}
      else
        _ -> nil
      end

    {report, shadow}
  end

  # A removal runs no code: nothing left on the branch, with the group's
  # changes, may still refer to the unit, and the root endpoint stays.
  defp removal_report(%Change{unit: unit, branch: branch, id: id}, group) do
    started = System.monotonic_time(:millisecond)
    removed = MapSet.new([unit | for(c <- group, Change.removes?(c), do: c.unit)])
    proposed = for c <- group, v <- c.candidates, into: %{}, do: {v.unit, v.ast}

    live =
      for %Unit{module: m, current_version: h} <- Branches.units(branch),
          {:ok, %Version{ast: ast}} <- [Ledger.version(m, h)],
          into: %{},
          do: {m, ast}

    holders =
      for {m, ast} <- Map.merge(live, proposed),
          not MapSet.member?(removed, m),
          not (Unit.spec_name?(m) and MapSet.member?(removed, Unit.specified_unit(m))),
          ast != nil and MapSet.member?(Unit.references(ast), unit),
          do: m

    violations =
      Enum.map(Enum.sort(holders), &"#{inspect(&1)} still refers to it") ++
        if(Theseus.Web.endpoint() == unit,
          do: ["it is the root endpoint, which answers every request"],
          else: []
        )

    static = %{
      name: :static,
      result: if(violations == [], do: :pass, else: :fail),
      detail: if(violations == [], do: nil, else: %{violations: %{unit => violations}}),
      ms: System.monotonic_time(:millisecond) - started
    }

    reason =
      if violations == [], do: "the change removes the unit", else: "an earlier stage failed"

    rest =
      for n <- @stages,
          n != :static,
          do: %{name: n, result: :skip, detail: %{reason: reason}, ms: 0}

    %Report{change_id: id, stages: [static | rest], passed: violations == []}
  end

  # Replays run on a snapshot of the app's data, held open for the
  # validation (see `Theseus.Store.Side`), with the branch's tables applied
  # inside each side's transaction; without a database, on an empty store
  # in memory.
  defp on_snapshot(ctx, fun) do
    with %{} <- Theseus.Store.DB.tables(),
         {:ok, holder, id} <- Theseus.Store.DB.export_snapshot() do
      try do
        snapshot = %{
          id: id,
          connection: Theseus.Store.DB.connection_opts(),
          prefix: Theseus.Store.DB.prefix()
        }

        fun.(Map.put(ctx, :snapshot, snapshot))
      after
        Theseus.Store.DB.release_snapshot(holder)
      end
    else
      {:error, why} ->
        Logger.warning("validating without the app's data: #{why}")
        fun.(ctx)

      _ ->
        fun.(ctx)
    end
  end

  # The schema unit whose backfill/2 would run when the change is approved,
  # with the tables before it, or nil.
  defp backfill(change, branch, after_) do
    with %Version{} = v <-
           Enum.find(change.candidates, &(&1.ast != nil and Theseus.Schema.schema_unit?(&1.ast))),
         {:ok, before} <- Theseus.Store.DB.branch_tables(branch),
         true <-
           Theseus.Store.Migrate.backfill?(v, Theseus.Schema.plan(before, after_ || %{}), branch) do
      %{unit: v.unit, before: before}
    else
      _ -> nil
    end
  end

  # The branch's tables as the group proposes them, for the store on the
  # sandbox: a schema unit the group changes counts as proposed. Nil
  # without any.
  defp store_tables(branch, candidates) do
    proposed =
      for %Version{unit: m, ast: ast} <- candidates,
          ast != nil and Theseus.Schema.schema_unit?(ast),
          {:ok, tables} <- [Theseus.Schema.from_ast(ast)],
          into: %{},
          do: {m, tables}

    live =
      for {m, tables} <- Theseus.Store.DB.schema_units(branch),
          not Map.has_key?(proposed, m),
          do: tables

    case Theseus.Schema.merge(live ++ Map.values(proposed)) do
      {:ok, tables} when map_size(tables) > 0 -> tables
      _ -> nil
    end
  end

  @doc "The module a candidate runs under during validation and shadowing."
  def candidate_name(%Version{unit: module, hash: hash}, run_id) do
    Module.concat([Theseus.Candidate, "V#{Version.short(hash)}x#{run_id}", module])
  end

  # What the sandbox node needs to know about the change's branch: every
  # unit and spec at its current version (an endpoint unit calls the
  # others), the server units to start there, the recorded calls, and the
  # candidate world (see the module doc).
  defp context(%Change{unit: unit, branch: branch} = change, group) do
    branch_units = Branches.units(branch)
    record = Enum.find(branch_units, &(&1.module == unit))

    spec_record =
      case Branches.unit(branch, Unit.spec_module(unit)) do
        %Unit{kind: :spec} = spec -> spec
        _ -> nil
      end

    live =
      for %Unit{module: m, current_version: hash} <- branch_units,
          {:ok, %Version{beam: beam}} <- [Ledger.version(m, hash)],
          is_binary(beam),
          do: {m, beam}

    kind = kind_of(Change.unit_candidate(change), record)

    endpoint_refs =
      for %Unit{kind: :endpoint, module: m, current_version: h} <- branch_units,
          {:ok, %Version{ast: ast}} <- [Ledger.version(m, h)],
          into: %{},
          do: {m, Unit.references(ast)}

    siblings =
      for c <- group, c.unit != unit, %Version{} = v <- [Change.unit_candidate(c)], do: v

    # Specs other changes of the group propose: a unit that calls a changed
    # unit is checked against its proposed spec, not its live one.
    sibling_specs =
      for c <- group, c.unit != unit, %Version{} = v <- [Change.spec_candidate(c)], do: v

    sibling_kinds =
      Map.new(siblings, fn v ->
        {v.unit, kind_of(v, Enum.find(branch_units, &(&1.module == v.unit)))}
      end)

    created = for v <- siblings, not Enum.any?(branch_units, &(&1.module == v.unit)), do: v.unit

    roots = roots(endpoint_refs, branch, change, kind, siblings, sibling_kinds)

    removed = for c <- group, Change.removes?(c), do: c.unit

    carried =
      carried(change, siblings, Enum.reject(branch_units, &(&1.module in removed)), branch)

    world =
      MapSet.new(
        Enum.map(siblings, & &1.unit) ++
          for(%{isolation: false, version: v} <- carried, do: v.unit)
      )

    calls_world? =
      case Change.unit_candidate(change) do
        %Version{ast: ast} -> Enum.any?(Unit.references(ast), &MapSet.member?(world, &1))
        nil -> false
      end

    %{
      unit: unit,
      branch: branch,
      kind: kind,
      registered?: record != nil,
      spec_module: spec_record && spec_record.module,
      spec_ast:
        with(
          %Unit{module: m, current_version: h} <- spec_record,
          {:ok, %Version{ast: ast}} <- Ledger.version(m, h),
          do: ast,
          else: (_ -> nil)
        ),
      live: live,
      units: for(%Unit{kind: k, module: m} <- branch_units, k != :spec, do: m) ++ created,
      pure_units:
        for(%Unit{kind: :pure, module: m} <- branch_units, do: m) ++
          Enum.filter(created, &(sibling_kinds[&1] == :pure)),
      servers: for(%Unit{kind: :server, module: m} <- branch_units, do: m),
      server_states: server_states(branch, branch_units),
      endpoint_refs: endpoint_refs,
      root: elem(roots, 0),
      world_root: elem(roots, 1),
      siblings: siblings,
      sibling_specs: sibling_specs,
      sibling_kinds: sibling_kinds,
      calls_world?: calls_world?,
      carried: carried,
      replay_set:
        if(record != nil and Change.unit_candidate(change) != nil,
          do: Traces.replay_set(unit, in_order: kind == :server),
          else: []
        ),
      signature: signature(change),
      store_tables: store_tables(branch, change.candidates ++ siblings),
      backfill: backfill(change, branch, store_tables(branch, change.candidates ++ siblings)),
      stage_timeout_ms: Application.fetch_env!(:theseus, :stage_timeout_ms)
    }
  end

  @max_state_bytes 1_000_000

  # A copy of the live server units' state, so comparisons replay recorded
  # calls against the data they were made with. Only for the live branch,
  # and only plain data under a size limit.
  defp server_states(branch, branch_units) do
    if branch == Branches.live() do
      for %Unit{kind: :server, module: m, current_version: version} <- branch_units,
          {:ok, pid} <- [Theseus.Servers.pid(m)],
          {:ok, state} <- [live_state(pid)],
          Theseus.State.plain?(state),
          byte_size(:erlang.term_to_binary(state)) <= @max_state_bytes,
          into: %{},
          do: {m, %{version: version, state: state}}
    else
      %{}
    end
  end

  defp live_state(pid) do
    {:ok, :sys.get_state(pid, 1_000)}
  catch
    :exit, _ -> :error
  end

  defp kind_of(_candidate, %Unit{kind: kind}), do: kind
  defp kind_of(%Version{unit: u, ast: ast}, nil), do: Unit.infer_kind(u, ast)
  defp kind_of(nil, nil), do: :pure

  # The units that call the changed units, directly or through each other,
  # at their live versions. Changed units are this change's unit and its
  # group's, when they change the unit itself (not only its spec).
  defp carried(change, siblings, branch_units, branch) do
    changed =
      for %Version{unit: m, ast: ast} <- [Change.unit_candidate(change) | siblings],
          into: %{},
          do: {m, ast}

    if changed == %{} do
      []
    else
      live =
        for %Unit{kind: k, module: m, current_version: hash} <- branch_units,
            k != :spec,
            not Map.has_key?(changed, m),
            {:ok, %Version{} = v} <- [Ledger.version(m, hash)],
            do: {m, %{version: %{v | beam: nil}, kind: k}}

      refs = Map.new(live, fn {m, %{version: v}} -> {m, Unit.references(v.ast)} end)
      reached = reach(MapSet.new(Map.keys(changed)), refs)

      dependents =
        for {m, entry} <- live, m in reached do
          spec_module = Unit.spec_module(m)

          Map.merge(entry, %{
            spec_module:
              if(match?(%Unit{kind: :spec}, Branches.unit(branch, spec_module)), do: spec_module),
            replay_set: Traces.replay_set(m, in_order: entry.kind == :server),
            isolation: false
          })
        end

      # Every server unit, and every unit that reaches one, gets its own copy
      # in the candidate world too, so "after" never shares state with
      # "before", and no unit of "after" reaches a live server. These are
      # not dependents: they run nothing of their own.
      servers = for {m, %{kind: :server}} <- live, do: m
      everything = reach(MapSet.union(MapSet.new(Map.keys(changed)), MapSet.new(servers)), refs)

      copies =
        for {m, entry} <- live, m in everything, m not in reached do
          Map.merge(entry, %{spec_module: nil, replay_set: [], isolation: true})
        end

      dependents ++ copies
    end
  end

  # Adds every unit that references a unit already in `set`, until none is left.
  defp reach(set, refs) do
    more =
      for {m, names} <- refs,
          m not in set,
          Enum.any?(names, &(&1 in set)),
          into: MapSet.new(),
          do: m

    if MapSet.size(more) == 0, do: set, else: reach(MapSet.union(set, more), refs)
  end

  defp signature(%Change{trigger: %{kind: :crash, payload: %{signature: signature}}}),
    do: signature

  defp signature(_change), do: nil

  # Every stage on the node can time out separately; this covers the node.
  defp sandbox_timeout, do: Application.fetch_env!(:theseus, :stage_timeout_ms) * 5 + 10_000

  defp static_stage(change, ctx) do
    started = System.monotonic_time(:millisecond)

    violations =
      for v <- change.candidates,
          kind = if(Unit.spec_name?(v.unit), do: :spec, else: ctx.kind),
          units = if(kind in [:server, :pure], do: ctx.pure_units, else: ctx.units),
          {:error, list} <- [Static.check(v, kind, units: units)],
          do: {v.unit, list}

    violations =
      case root_cycle(change, ctx) do
        nil -> violations
        message -> [{change.unit, [message]} | violations]
      end

    # A schema unit only adds tables, columns and indexes (Theseus.Schema).
    violations =
      violations ++
        for v <- change.candidates,
            v.ast != nil and Theseus.Schema.schema_unit?(v.ast),
            {:error, reasons} <-
              [Theseus.Store.DB.check(v, change.branch, change.candidates ++ ctx.siblings)],
            do: {v.unit, reasons}

    # A services unit reads, and declares each service once (Theseus.Services).
    violations =
      violations ++
        for v <- change.candidates,
            v.ast != nil and Theseus.Services.services_unit?(v.ast),
            {:error, reasons} <- [Theseus.Services.check(v, change.branch)],
            do: {v.unit, reasons}

    {result, detail} =
      if violations == [],
        do: {:pass, nil},
        else:
          {:fail,
           %{
             violations:
               violations
               |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
               |> Map.new(fn {u, l} -> {u, Enum.concat(l)} end)
           }}

    %{
      name: :static,
      result: result,
      detail: detail,
      ms: System.monotonic_time(:millisecond) - started
    }
  end

  # A change to an endpoint unit that leaves the endpoint units calling each
  # other in a cycle, with none clearly the one that receives requests, is
  # refused. An app that was already like that is not blocked by it.
  defp root_cycle(change, ctx) do
    endpoint? = fn m ->
      if m == change.unit, do: ctx.kind == :endpoint, else: ctx.sibling_kinds[m] == :endpoint
    end

    changed =
      for %Version{unit: m, ast: ast} <- [Change.unit_candidate(change) | ctx.siblings],
          endpoint?.(m),
          into: %{},
          do: {m, Unit.references(ast)}

    calls = fn refs ->
      Map.new(refs, fn {m, r} -> {m, Enum.filter(Map.keys(refs), &MapSet.member?(r, &1))} end)
    end

    with true <- Map.has_key?(changed, change.unit),
         nil <- Theseus.Web.root_cycle(calls.(ctx.endpoint_refs)),
         [_ | _] = cycle <- Theseus.Web.root_cycle(calls.(Map.merge(ctx.endpoint_refs, changed))) do
      "#{Enum.map_join(cycle, " and ", &inspect/1)} would call each other, so no endpoint unit " <>
        "would clearly be the one that receives requests. Keep the root the only endpoint unit " <>
        "no other unit calls; move shared page code into a pure unit."
    else
      _ -> nil
    end
  end

  @doc false
  # Runs on the sandbox node. Returns the stages and the candidates' beams.
  def run_sandboxed(change, renamed, ctx) do
    Process.group_leader(self(), Sandbox.sink_device())
    Application.put_env(:theseus, :stage_timeout_ms, ctx.stage_timeout_ms)
    {:ok, _} = Task.Supervisor.start_link(name: Theseus.TaskSupervisor)

    for {module, beam} <- ctx.live do
      {:module, ^module} = :code.load_binary(module, ~c"live/#{inspect(module)}.beam", beam)
    end

    # Endpoint units call the branch's units directly here, and server units
    # run with fresh state. The store is in memory, checked against the
    # branch's tables.
    Theseus.Call.sandbox!()
    :persistent_term.put({Theseus.Store, :tables}, ctx[:store_tables])

    for module <- ctx.servers do
      try do
        with {:ok, pid} <- module.start_link([]), do: Process.unlink(pid)
      catch
        _, _ -> :ok
      end
    end

    {stages, beams} =
      Enum.reduce_while(
        [:compile, :spec, :backfill, :behaviour, :replay, :dependents],
        {[], %{}},
        fn
          step, {acc, beams} ->
            {new, beams} = run_step(step, change, renamed, ctx, acc, beams)
            acc = acc ++ new

            if Enum.any?(new, &(&1.result == :fail)),
              do: {:halt, {acc, beams}},
              else: {:cont, {acc, beams}}
        end
      )

    {stages, beams}
  end

  defp run_step(:compile, change, renamed, ctx, _done, beams) do
    started = System.monotonic_time(:millisecond)

    rewrite = world_names(change, renamed, ctx)

    outcome =
      isolated(fn ->
        for v <-
              change.candidates ++
                ctx.siblings ++ ctx.sibling_specs ++ Enum.map(ctx.carried, & &1.version) do
          name = renamed[v.unit]
          names = if Unit.spec_name?(v.unit), do: %{}, else: Map.delete(rewrite, v.unit)
          {v.unit, name, load_candidate(v, name, names)}
        end
      end)

    ms = System.monotonic_time(:millisecond) - started

    case outcome do
      {:ok, results} ->
        # The group's own code compiles without warnings; a unit carried
        # along for comparison may have older ones.
        own = MapSet.new(change.candidates ++ ctx.siblings ++ ctx.sibling_specs, & &1.unit)

        errors =
          for({unit, _name, {:error, reason}} <- results, do: {unit, reason}) ++
            for(
              {unit, _name, {:ok, _beam, [_ | _] = warnings}} <- results,
              MapSet.member?(own, unit),
              do: {unit, {:warnings, warnings}}
            )

        # A seed unit's rows must fit the branch's tables (Theseus.Seed).
        errors =
          if errors == [],
            do: seed_errors(change, renamed, ctx),
            else: errors

        compiled = for {_unit, name, {:ok, beam, _}} <- results, into: beams, do: {name, beam}

        # Candidate server units run under their candidate names, so the
        # candidates that call them reach them.
        if errors == [], do: restart_servers(ctx, renamed, :fresh)

        if errors == [],
          do: {[%{name: :compile, result: :pass, detail: nil, ms: ms}], compiled},
          else:
            {[%{name: :compile, result: :fail, detail: %{errors: Map.new(errors)}, ms: ms}],
             beams}

      {:error, reason} ->
        {[%{name: :compile, result: :fail, detail: reason, ms: ms}], beams}
    end
  end

  # A schema change whose backfill/2 runs at promotion runs it here over the
  # app's data first (Theseus.Store.Migrate.preview/3).
  defp run_step(:backfill, _change, renamed, ctx, _done, beams) do
    case ctx[:backfill] do
      %{unit: unit, before: before} ->
        {[stage(:backfill, fn -> Theseus.Store.Migrate.preview(renamed[unit], before, ctx) end)],
         beams}

      nil ->
        {[], beams}
    end
  end

  defp run_step(:spec, change, renamed, ctx, _done, beams) do
    started = System.monotonic_time(:millisecond)

    outcome =
      isolated(fn ->
        with {:ok, spec} <- spec_for(change, renamed, ctx) do
          {:ok, Spec.run(spec, module_under_test(change, renamed), spec_opts(ctx, renamed))}
        end
      end)

    ms = System.monotonic_time(:millisecond) - started

    stages =
      case outcome do
        {:ok, {:ok, report}} ->
          for {name, kind} <- [examples: :example, properties: :property, invariants: :invariant] do
            results = Enum.filter(report.results, &(&1.kind == kind))

            failed =
              for %{result: {:fail, detail}} = r <- results, do: %{name: r.name, detail: detail}

            cond do
              results == [] ->
                %{name: name, result: :skip, detail: %{reason: "none in the spec"}, ms: 0}

              failed == [] ->
                %{name: name, result: :pass, detail: %{count: length(results)}, ms: ms}

              true ->
                %{name: name, result: :fail, detail: %{failed: failed}, ms: ms}
            end
          end
          |> stop_after_failure()

        {:ok, {:error, reason}} ->
          [%{name: :examples, result: :fail, detail: %{error: reason}, ms: ms}]

        {:error, reason} ->
          [%{name: :examples, result: :fail, detail: reason, ms: ms}]
      end

    {stages, beams}
  end

  # Comparisons start both systems from a copy of the live server state
  # (when there is one); the proposed spec runs on fresh state.
  defp run_step(:behaviour, change, renamed, ctx, _done, beams) do
    hooks = [
      before_each: fn -> revive_servers(ctx, renamed) end,
      fresh: fn -> restart_servers(ctx, renamed, :fresh) end,
      live_app: ctx.root && fn fun, args -> apply(ctx.root, fun, args) end,
      live: fn -> restart_servers(ctx, renamed, :live) end
    ]

    {[stage(:behaviour, fn -> {:info, Behaviour.compare(change, renamed, ctx, hooks)} end)],
     beams}
  end

  defp run_step(:replay, change, renamed, ctx, done, beams) do
    {[stage(:replay, fn -> replay(change, renamed, ctx, done) end)], beams}
  end

  defp run_step(:dependents, change, renamed, ctx, _done, beams) do
    {[stage(:dependents, fn -> dependents(change, renamed, ctx) end)], beams}
  end

  # A seed unit's rows must fit the branch's tables (Theseus.Seed).
  # Whose turn a validation takes in the sandbox queue: the person behind
  # an MCP request, the change's proposer, or the engine.
  defp queue_owner(change),
    do: Theseus.Team.acting() || change.proposer[:person] || :engine

  defp seed_errors(change, renamed, ctx) do
    for v <- change.candidates,
        Theseus.Seed.seed_unit?(v.ast),
        {:error, why} <- [seed_check(renamed[v.unit], ctx)],
        do: {v.unit, {:seed, why}}
  end

  defp seed_check(module, ctx) do
    case isolated(fn -> Theseus.Seed.check(module, ctx[:store_tables]) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, Theseus.Describe.text(reason)}
    end
  end

  # A change's own unit is checked by its own spec stage, even when it also
  # calls a changed unit of its group.
  defp dependents(change, renamed, ctx) do
    case Enum.reject(ctx.carried, &(&1.isolation or &1.version.unit == change.unit)) do
      [] -> {:skip, %{reason: "no other unit calls the changed units"}}
      carried -> dependents(change, renamed, ctx, carried)
    end
  end

  defp dependents(change, renamed, ctx, carried) do
    units =
      for %{version: %Version{unit: m}, kind: kind, spec_module: spec_module} = entry <-
            carried do
        candidate = renamed[m]

        spec =
          case Enum.find(ctx.sibling_specs, &(&1.unit == Unit.spec_module(m))) do
            %Version{unit: proposed} -> renamed[proposed].__spec__()
            nil -> spec_module && spec_module.__spec__()
          end

        # Specs run on fresh server state; replays on a copy of the live
        # state. Restarting also brings back servers an earlier replay
        # crashed.
        restart_servers(ctx, renamed, :fresh)

        failed =
          if spec,
            do:
              for(
                %{result: {:fail, detail}} = r <-
                  Spec.run(spec, candidate, spec_opts(ctx, renamed)).results,
                do: %{name: r.name, detail: detail}
              ),
            else: []

        traces =
          if entry.replay_set != [] do
            restart_servers(ctx, renamed, :live)
            equivalent = (spec || %Spec{unit: m}).equivalence

            Behaviour.replay_calls(m, candidate, entry.replay_set, equivalent, ctx.signature,
              through: true,
              before_each: fn -> revive_servers(ctx, renamed) end,
              snapshot: ctx[:snapshot],
              tables: ctx[:store_tables]
            )
          end

        %{unit: m, kind: kind, spec?: spec != nil, failed: failed, traces: traces}
      end

    differ = Enum.sum(for %{traces: %{differ: d}} <- units, do: d)

    cond do
      Enum.any?(units, &(&1.failed != [])) ->
        {:fail, %{units: units}}

      differ > 0 and not change.behaviour_change ->
        {:fail, %{units: units, keeps_behaviour: true}}

      differ > 0 ->
        {:info, %{units: units}}

      true ->
        {:pass, %{units: units}}
    end
  end

  # Unit name => candidate name, for every unit in the candidate world.
  defp world_names(change, renamed, ctx) do
    units =
      [Change.unit_candidate(change) | ctx.siblings]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.unit)
      |> Kernel.++(Enum.map(ctx.carried, & &1.version.unit))

    Map.new(units, &{&1, renamed[&1]})
  end

  # The server units of both systems, as `{module to run, unit, role}`: live
  # ones under their own names, and candidate ones (changed, in the group,
  # or calling changed units) under their candidate names.
  defp world_servers(ctx, renamed) do
    changed =
      if(ctx.kind == :server and renamed[ctx.unit], do: [ctx.unit], else: []) ++
        for(v <- ctx.siblings, ctx.sibling_kinds[v.unit] == :server, do: v.unit)

    carried = for %{kind: :server, version: v} <- ctx.carried, do: v.unit

    for(m <- ctx.servers, do: {m, m, :live}) ++
      for(m <- changed, renamed[m], do: {renamed[m], m, :changed}) ++
      for(m <- carried, renamed[m], do: {renamed[m], m, :carried})
  end

  # Every rule of a spec starts on fresh server state, so rules do not see
  # each other's records.
  defp fresh(ctx, renamed), do: fn -> restart_servers(ctx, renamed, :fresh) end

  # The root endpoint unit, of the branch as it is (for the live check) and
  # of the candidate world, which counts endpoint units this change and its
  # group create or change.
  defp roots(endpoint_refs, branch, change, kind, siblings, sibling_kinds) do
    previous = if branch == Theseus.Branches.live(), do: Theseus.Web.endpoint()
    live_root = Theseus.Web.root_of(endpoint_refs, previous)

    changed =
      for %Version{unit: m, ast: ast} <- [Change.unit_candidate(change) | siblings],
          if(m == change.unit, do: kind, else: sibling_kinds[m]) == :endpoint,
          into: %{},
          do: {m, Unit.references(ast)}

    {live_root, Theseus.Web.root_of(Map.merge(endpoint_refs, changed), live_root)}
  end

  # Spec options: fresh state for every rule, and `app` calling the root
  # endpoint unit as it is in the candidate world (its copy or candidate when
  # it is there, the live one otherwise).
  defp spec_opts(ctx, renamed) do
    app =
      case ctx.world_root do
        nil ->
          [
            app: fn _fun, _args ->
              raise ArgumentError, "the app has no endpoint unit yet, so app has nothing to call"
            end
          ]

        root ->
          target = Map.get(renamed, root, root)
          [app: fn fun, args -> apply(target, fun, args) end]
      end

    [before_each: fresh(ctx, renamed)] ++ app
  end

  defp restart_servers(ctx, renamed, mode) do
    for {module, _unit, _role} = server <- world_servers(ctx, renamed) do
      try do
        case Process.whereis(module) do
          nil -> :ok
          pid -> GenServer.stop(pid, :normal, 1_000)
        end
      catch
        _, _ -> :ok
      end

      start_server(server, ctx, mode)
    end
  end

  # Unlinked: a recorded call that crashes a server unit must not take the
  # validation down with it.
  defp start_server({module, unit, role}, ctx, mode) do
    with true <- function_exported?(module, :start_link, 1),
         {:ok, pid} <- module.start_link([]),
         true <- Process.unlink(pid),
         :live <- mode,
         %{version: version, state: state} <- ctx.server_states[unit] do
      put_state(pid, module, role, version, state)
    end
  catch
    _, _ -> :ok
  end

  # A recorded call that crashed a server unit crashed it on both sides;
  # bring both back from the live state before the next call.
  defp revive_servers(ctx, renamed) do
    if Enum.any?(world_servers(ctx, renamed), fn {module, _, _} ->
         Process.whereis(module) == nil
       end),
       do: restart_servers(ctx, renamed, :live)

    :ok
  end

  # A changed server unit gets the live state migrated with its own
  # code_change/3, as on approval; the others take it as it is.
  defp put_state(pid, module, :changed, version, state) do
    case module.code_change(version, state, nil) do
      {:ok, migrated} -> :sys.replace_state(pid, fn _ -> migrated end)
      _ -> :ok
    end
  end

  defp put_state(pid, _module, _role, _version, state),
    do: :sys.replace_state(pid, fn _ -> state end)

  defp replay(change, renamed, ctx, done) do
    traces =
      case Enum.find(done, &(&1.name == :behaviour)) do
        %{detail: %{traces: traces}} -> traces
        _ -> nil
      end

    crash_fix? = ctx.signature != nil

    cond do
      Change.creates?(change) ->
        {:skip, %{reason: "a new unit has no recorded calls"}}

      traces == nil ->
        {:skip, %{reason: "the unit itself does not change"}}

      crash_fix? and traces.counts.fixed + traces.counts.unfixed == 0 ->
        {:fail, %{reason: "no recorded call reproduces the crash, so the fix cannot be checked"}}

      crash_fix? and traces.differ == 0 ->
        {:pass, Map.take(traces, [:compared, :differ, :counts])}

      crash_fix? ->
        {:fail, Map.take(traces, [:compared, :differ, :counts])}

      Map.get(traces, :dropped_callbacks, []) != [] and not change.behaviour_change ->
        {:fail,
         %{
           reason:
             "the proposed version no longer has #{Enum.join(traces.dropped_callbacks, " and ")}, " <>
               "which the engine calls, but the change says it keeps behaviour"
         }}

      traces.compared == 0 and Map.get(traces.counts, :removed, 0) > 0 ->
        {:skip,
         %{reason: "every recorded call is to a function the proposed version no longer has"}}

      traces.compared == 0 ->
        {:skip, %{reason: "no recorded calls yet"}}

      Map.get(traces.counts, :refused_messages, 0) > 0 ->
        {:fail,
         %{
           reason:
             "#{traces.counts.refused_messages} messages the recorded calls would send are ones " <>
               "the outbox refuses, such as one where #{traces.refused_example}"
         }}

      Map.get(traces.counts, :refused_writes, 0) > 0 ->
        {:fail,
         %{
           reason:
             "#{traces.counts.refused_writes} answers to recorded calls return writes the store " <>
               "refuses, such as one where #{traces.refused_writes_example}"
         }}

      Map.get(traces.counts, :refused_htmx, 0) > 0 ->
        {:fail,
         %{
           reason:
             "#{traces.counts.refused_htmx} answers to recorded calls set htmx headers the engine " <>
               "refuses, such as one where #{traces.refused_htmx_example}"
         }}

      change.behaviour_change ->
        {:info, Map.take(traces, [:compared, :differ, :data])}

      not deterministic?(change, renamed, ctx) ->
        {:skip, %{reason: "the spec says this unit's results can vary between runs"}}

      traces.differ == 0 ->
        {:pass, Map.take(traces, [:compared, :data])}

      true ->
        {:fail, Map.take(traces, [:compared, :differ, :data])}
    end
  end

  defp deterministic?(change, renamed, ctx) do
    case spec_for(change, renamed, ctx) do
      {:ok, spec} -> spec.deterministic
      {:error, _} -> true
    end
  end

  defp shadow_stage(change, ctx, opts) do
    skip = fn reason -> %{name: :shadow, result: :skip, detail: %{reason: reason}, ms: 0} end

    case Shadow.plan(change) do
      {:skip, reason} ->
        skip.(reason)

      # The shadow run uses the candidate on the live node, where the other
      # candidates it would call do not exist.
      {:run, _limits} when ctx.calls_world? ->
        skip.("it calls other units that change with it, which run only on the sandbox")

      {:run, limits} ->
        if Keyword.get(opts, :shadow, false),
          do: %{name: :shadow, result: :running, detail: limits, ms: 0},
          else: skip.("runs on live calls after the change is proposed")
    end
  end

  # Within the spec stages, a failure skips the stages after it.
  defp stop_after_failure(stages) do
    {kept, _} =
      Enum.map_reduce(stages, false, fn
        stage, true ->
          {%{stage | result: :skip, detail: %{reason: "an earlier stage failed"}}, true}

        stage, false ->
          {stage, stage.result == :fail}
      end)

    kept
  end

  defp pad_skipped(stages) do
    done = MapSet.new(stages, & &1.name)

    skipped =
      for n <- @stages,
          n not in done,
          do: %{name: n, result: :skip, detail: %{reason: "an earlier stage failed"}, ms: 0}

    stages ++ skipped
  end

  @doc false
  # The spec that judges the change: the candidate spec, or the live one.
  def spec_for(change, renamed, ctx) do
    case Change.spec_candidate(change) do
      %Version{unit: spec_module} ->
        {:ok, renamed[spec_module].__spec__()}

      nil ->
        case ctx.spec_module do
          nil -> {:error, "#{inspect(change.unit)} has no live spec"}
          spec_module -> {:ok, spec_module.__spec__()}
        end
    end
  end

  # A change to the spec alone runs against the unit's copy in the candidate
  # world when there is one (it calls a unit the group changes), and against
  # the live unit otherwise.
  defp module_under_test(change, renamed) do
    case Change.unit_candidate(change) do
      %Version{unit: unit} -> renamed[unit]
      nil -> Map.get(renamed, change.unit, change.unit)
    end
  end

  @doc """
  Compiles a candidate under the module name `name`, loads it there, returns
  its beam. `names` renames the other units it refers to.
  """
  @spec load_candidate(Version.t(), module(), %{module() => module()}) ::
          {:ok, binary(), [String.t()]} | {:error, term()}
  def load_candidate(%Version{} = version, name, names \\ %{}) do
    {:defmodule, meta, [_name, body]} = version.ast
    body = Unit.rename_references(body, names)
    renamed = %{version | unit: name, ast: {:defmodule, meta, [name, body]}}

    with {:ok, beam, warnings} <- Theseus.Loader.compile_checked(renamed) do
      case :code.load_binary(name, ~c"theseus/candidate/#{inspect(name)}.beam", beam) do
        {:module, ^name} -> {:ok, beam, warnings}
        {:error, reason} -> {:error, {:load_failed, reason}}
      end
    end
  end

  defp stage(name, fun) do
    started = System.monotonic_time(:millisecond)

    {result, detail} =
      case isolated(fun) do
        {:ok, {result, detail}} -> {result, detail}
        {:error, reason} -> {:fail, reason}
      end

    %{
      name: name,
      result: result,
      detail: detail,
      ms: System.monotonic_time(:millisecond) - started
    }
  end

  @doc """
  Runs candidate code in a separate, unlinked process with the stage
  timeout. The process gets its own group leader, which everything it
  spawns inherits (the compiler's workers are not linked to it). On timeout
  the whole group is killed, so a candidate that loops while compiling stops
  too. Returns `{:ok, value}` or `{:error, reason}`.
  """
  def isolated(fun) do
    timeout = Application.fetch_env!(:theseus, :stage_timeout_ms)
    proxy = spawn(fn -> forward_io(Process.group_leader()) end)

    task =
      Task.Supervisor.async_nolink(Theseus.TaskSupervisor, fn ->
        Process.group_leader(self(), proxy)
        fun.()
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} -> {:ok, value}
        {:exit, reason} -> {:error, %{crashed: Exception.format_exit(reason)}}
        nil -> {:error, %{timeout_ms: timeout}}
      end

    for pid <- Process.list(), Process.info(pid, :group_leader) == {:group_leader, proxy} do
      Process.exit(pid, :kill)
    end

    Process.exit(proxy, :kill)
    result
  end

  defp forward_io(group_leader) do
    receive do
      message ->
        send(group_leader, message)
        forward_io(group_leader)
    end
  end

  @doc "Unloads a candidate module."
  def purge(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end
end
