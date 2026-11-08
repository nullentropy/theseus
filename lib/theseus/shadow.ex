defmodule Theseus.Shadow do
  @moduledoc """
  Runs a candidate beside the live unit on live calls, before a person is
  asked to decide.

  While a shadow is registered for a unit, `Theseus.call/3` hands each
  call's arguments and live result to this process. It runs the candidate
  (compiled on the sandbox node during validation and loaded here under its
  renamed module, never in the live slot) on the same
  arguments in a separate process with a time limit, and compares the
  results with the spec's equivalence. The live call never waits for the
  candidate and never sees its result or its errors.

  A shadow ends after `:shadow_calls` compared calls or `:shadow_ms`
  milliseconds, whichever comes first. Its result goes to `Theseus.Changes`
  as the report's `:shadow` stage: a change that says it keeps behaviour
  fails if any live call behaves differently; a behaviour change only
  reports the differences. For a crash fix, live calls that fail with the
  crash's signature must now succeed.

  A server unit's candidate runs as its own process under the candidate's
  name, started from a copy of the live process's state (migrated with the
  candidate's `code_change/3`; the live process is suspended for the moment
  it takes, at most `:shadow_migrate_ms`, default 1 s, so no call is
  missed). Its calls to other units are not recorded, except any its
  `init/1` makes before the process is marked. It gets the live calls one at a time, in
  the order they finish, so its state follows the live one. Calls that
  reach the live process another way (its own timers) do not reach the
  candidate, and concurrent callers may finish in another order than the
  live process served them; both show as differences.

  An endpoint unit's candidate is shadowed when every unit it calls is a
  pure unit, which a second call cannot affect. It reads the data the live
  call read: the live call's store transaction exports its snapshot when
  the call returns, before its writes are applied, and the candidate runs
  in a read-only transaction on that snapshot, on a pool of its own
  (`Theseus.Store.ShadowPool`), which is rolled back. The live call waits
  until the candidate's transaction has taken the snapshot, at most
  #{500} ms, and not for the candidate. The writes the candidate returns are
  compared with the live ones, and never applied.
  """

  use GenServer

  alias Theseus.{Change, Redact, Registry, Spec, Validator}
  alias Theseus.Validator.Behaviour

  @table :theseus_shadows
  @max_in_flight 4
  @max_queued 1_000
  @call_timeout_ms 2_000
  @import_wait_ms 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether a proposed change gets a shadow run, and its limits."
  @spec plan(Change.t()) ::
          {:run, %{calls: pos_integer(), ms: pos_integer()}} | {:skip, String.t()}
  def plan(%Change{} = change) do
    calls = Application.get_env(:theseus, :shadow_calls, 50)
    ms = Application.get_env(:theseus, :shadow_ms, 60_000)

    cond do
      change.branch != Theseus.Branches.live() ->
        {:skip, "the branch is not live"}

      Change.creates?(change) ->
        {:skip, "a new unit has no live calls"}

      Change.unit_candidate(change) == nil ->
        {:skip, "the unit itself does not change"}

      server?(change.unit) and Theseus.Servers.pid(change.unit) == :error ->
        {:skip, "the server unit is not running"}

      (why = endpoint_refusal(change)) != nil ->
        {:skip, why}

      calls < 1 or ms < 1 ->
        {:skip, "shadow runs are turned off"}

      true ->
        {:run, %{calls: calls, ms: ms}}
    end
  end

  @doc """
  Starts shadowing a change's unit candidate, given as the renamed module and
  its beam from validation. The result arrives at `Theseus.Changes`.
  """
  @spec start(Change.t(), %{calls: pos_integer(), ms: pos_integer()}, {module(), binary()}) ::
          :ok | {:error, term()}
  def start(%Change{} = change, limits, {module, beam}),
    do: GenServer.call(__MODULE__, {:start, change, limits, module, beam}, 60_000)

  defp server?(unit), do: match?({:ok, %{kind: :server}}, Registry.fetch(unit))

  # An endpoint candidate that calls anything but pure units would repeat
  # those calls' effects.
  defp endpoint_refusal(change) do
    with true <- endpoint?(change),
         %{ast: ast} when ast != nil <- Change.unit_candidate(change),
         [_ | _] = others <-
           ast
           |> Theseus.Unit.references()
           |> Enum.filter(&match?({:ok, %{kind: k}} when k != :pure, Registry.fetch(&1)))
           |> Enum.sort() do
      "it calls #{Enum.map_join(others, ", ", &inspect/1)}, which a second run would call again; only an endpoint unit that calls pure units alone is shadowed"
    else
      _ -> nil
    end
  end

  defp endpoint?(%Change{unit: unit} = change) do
    case Registry.fetch(unit) do
      {:ok, %{kind: kind}} ->
        kind in [:endpoint, :store]

      :error ->
        with(
          %{unit: u, ast: ast} <- Change.unit_candidate(change),
          do: Theseus.Unit.infer_kind(u, ast) in [:endpoint, :store]
        )
    end
  end

  @doc "Stops a shadow without reporting it."
  @spec stop(String.t()) :: :ok
  def stop(change_id), do: GenServer.call(__MODULE__, {:stop, change_id})

  @spec running?(String.t()) :: boolean()
  def running?(change_id), do: progress(change_id) != nil

  @doc "How far a running shadow has got, or nil."
  @spec progress(String.t()) :: map() | nil
  def progress(change_id), do: GenServer.call(__MODULE__, {:progress, change_id})

  @doc false
  # Called by `Theseus.call/3` after every live call. Never raises.
  def tee(unit, fun, args, live) do
    case lookup(unit) do
      [] ->
        :ok

      [{_unit, _id, :endpoint} | _] ->
        tee_endpoint(unit, fun, args, live)

      _plain ->
        GenServer.cast(
          Theseus.Leader.name(__MODULE__),
          {:tee, unit, fun, args, live, System.monotonic_time(), nil}
        )
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # The candidate must take the live transaction's snapshot while that
  # transaction is open, so the live call waits for it, briefly.
  defp tee_endpoint(unit, fun, args, live) do
    case Theseus.Store.shadow_source() do
      :unavailable ->
        :ok

      source ->
        ref = make_ref()
        at = System.monotonic_time()
        # The whole wait, the call included.
        deadline = System.monotonic_time(:millisecond) + @import_wait_ms

        n =
          GenServer.call(
            Theseus.Leader.name(__MODULE__),
            {:tee, unit, fun, args, live, at, {source, self(), ref}},
            @import_wait_ms
          )

        for _ <- 1..n//1, do: await_import(ref, deadline)
        :ok
    end
  end

  # Shadows run on the leader. A follower hands its live calls to them too,
  # and knows which units have one from the copy the leader sends it.
  defp lookup(unit) do
    if Theseus.Leader.leader?(),
      do: :ets.lookup(@table, unit),
      else: Map.get(:persistent_term.get({__MODULE__, :mirror}, %{}), unit, [])
  end

  defp mirror do
    rows = shadowed()
    for node <- Theseus.Leader.followers(), do: :erpc.cast(node, __MODULE__, :mirrored, [rows])
  end

  @doc false
  # On the leader: every shadowed unit's rows.
  def shadowed do
    if :ets.whereis(@table) == :undefined,
      do: %{},
      else: @table |> :ets.tab2list() |> Enum.group_by(&elem(&1, 0))
  end

  @doc false
  # On a follower: the leader's shadowed units.
  def mirrored(rows) do
    if :persistent_term.get({__MODULE__, :mirror}, nil) != rows,
      do: :persistent_term.put({__MODULE__, :mirror}, rows)

    :ok
  end

  @doc false
  # On a follower that has just reached the leader.
  def mirror_from(leader) do
    mirrored(:erpc.call(leader, __MODULE__, :shadowed, [], 5_000))
  catch
    _, _ -> :ok
  end

  defp await_import(ref, deadline) do
    receive do
      {^ref, :imported} -> :ok
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :ok
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:bag, :named_table, :protected, read_concurrency: true])
    {:ok, %{shadows: %{}, workers: %{}}}
  end

  @impl true
  def handle_call({:start, change, limits, module, beam}, _from, state) do
    unit = change.unit

    with {:module, ^module} <-
           :code.load_binary(module, ~c"theseus/shadow/#{inspect(module)}.beam", beam),
         {:ok, server, copied_at} <- register(unit, module, change) do
      shadow = %{
        server: server,
        copied_at: copied_at,
        queue: :queue.new(),
        id: change.id,
        unit: unit,
        module: module,
        signature: signature(change),
        behaviour_change: change.behaviour_change,
        calls: limits.calls,
        ms: limits.ms,
        ends_at: DateTime.add(DateTime.utc_now(), limits.ms, :millisecond),
        started_at: System.monotonic_time(:millisecond),
        timer: Process.send_after(self(), {:window_closed, change.id}, limits.ms),
        started: 0,
        items: []
      }

      {:reply, :ok, put_in(state.shadows[change.id], shadow)}
    else
      {:error, {:candidate_server, _, _} = reason} ->
        Validator.purge(module)
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        Validator.purge(module)
        {:reply, {:error, {:load_failed, reason}}, state}
    end
  end

  def handle_call({:tee, _unit, _fun, _args, _live, _at, _source} = tee, _from, state) do
    before = map_size(state.workers)
    state = do_tee(state, tee)
    {:reply, map_size(state.workers) - before, state}
  end

  def handle_call({:stop, id}, _from, state), do: {:reply, :ok, finish(state, id, false)}

  def handle_call({:progress, id}, _from, state) do
    reply =
      with %{} = s <- state.shadows[id] do
        summary = Behaviour.summary(s.items)

        %{
          compared: summary.compared,
          differ: summary.differ,
          calls: s.calls,
          ends_at: s.ends_at
        }
      end

    {:reply, reply, state}
  end

  @impl true
  # A server shadow skips calls that finished before the live process was
  # resumed: the live process served them before its state was copied.
  def handle_cast({:tee, _unit, _fun, _args, _live, _at, _source} = tee, state),
    do: {:noreply, do_tee(state, tee)}

  defp do_tee(state, {:tee, unit, fun, args, live, at, source}) do
    ids =
      for {_unit, id, _mode} <- :ets.lookup(@table, unit),
          not served_before_copy?(state.shadows[id], at),
          do: id

    Enum.reduce(ids, state, &maybe_run(&2, &1, fun, args, live, source))
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        {:noreply, server_down(state, ref)}

      {worker, workers} ->
        Process.cancel_timer(worker.timer)
        state = %{state | workers: workers}
        handle_done(state, worker, reason)
    end
  end

  def handle_info({:too_slow, ref}, state) do
    with %{pid: pid} <- state.workers[ref], do: Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:window_closed, id}, state), do: {:noreply, finish(state, id, true)}

  # An endpoint candidate that could not take the live call's snapshot
  # compares nothing: the call is not counted.
  defp handle_done(state, worker, {:shadow_skipped, _why}) do
    case state.shadows[worker.id] do
      nil -> {:noreply, state}
      s -> {:noreply, put_in(state.shadows[worker.id], %{s | started: s.started - 1})}
    end
  end

  defp handle_done(state, worker, reason) do
    # Rows end up in the ledger; live calls were never redacted.
    item = worker |> item(reason) |> redact()

    case state.shadows[worker.id] do
      nil ->
        {:noreply, state}

      s ->
        s = %{s | items: [item | s.items]}
        state = put_in(state.shadows[worker.id], s)

        if length(s.items) >= s.calls,
          do: {:noreply, finish(state, worker.id, true)},
          else: {:noreply, next_queued(state, worker.id)}
    end
  end

  ## Internals

  defp signature(%Change{trigger: %{kind: :crash, payload: %{signature: s}}}), do: s
  defp signature(_change), do: nil

  # Registers the shadow for live calls. For a server unit, first starts the
  # candidate's process from the live state, with the live process
  # suspended so that every call after the copy is teed. The migration
  # runs in its own process with a time limit, and the live process is
  # always resumed.
  defp register(unit, module, %Change{id: id} = change) do
    if server?(unit) do
      with {:ok, live} <- Theseus.Servers.pid(unit),
           {:ok, %{current_version: version}} <- Registry.fetch(unit) do
        :sys.suspend(live)

        try do
          with {:ok, pid} <- start_candidate(live, module, version) do
            :ets.insert(@table, {unit, id, :plain})
            mirror()
            # Taken before the live process resumes: every call that
            # finishes later than this was served after the copy.
            {:ok, %{pid: pid, ref: Process.monitor(pid)}, System.monotonic_time()}
          end
        after
          :sys.resume(live)
        end
      else
        _ -> {:error, :server_not_running}
      end
    else
      :ets.insert(@table, {unit, id, if(endpoint?(change), do: :endpoint, else: :plain)})
      mirror()
      {:ok, nil, nil}
    end
  end

  defp start_candidate(live, module, version) do
    # Well under GenServer.call's 5 s default, so live callers waiting on
    # the suspended process do not time out.
    limit = Application.get_env(:theseus, :shadow_migrate_ms, 1_000)

    {helper, ref} =
      spawn_monitor(fn ->
        Theseus.Call.untraced!()

        try do
          {:ok, migrated} = module.code_change(version, :sys.get_state(live), nil)
          {:ok, pid} = module.start_link([])
          Process.unlink(pid)

          :sys.replace_state(pid, fn _ ->
            Theseus.Call.untraced!()
            migrated
          end)

          exit({:started, pid})
        catch
          :exit, {:started, _} = started -> exit(started)
          kind, reason -> exit({:failed, kind, reason})
        end
      end)

    receive do
      {:DOWN, ^ref, :process, ^helper, {:started, pid}} ->
        {:ok, pid}

      {:DOWN, ^ref, :process, ^helper, {:failed, kind, reason}} ->
        {:error, {:candidate_server, kind, reason}}

      {:DOWN, ^ref, :process, ^helper, reason} ->
        {:error, {:candidate_server, :exit, reason}}
    after
      limit ->
        Process.demonitor(ref, [:flush])
        Process.exit(helper, :kill)
        with pid when is_pid(pid) <- Process.whereis(module), do: Process.exit(pid, :kill)

        {:error, {:candidate_server, :exit, "taking the live state took longer than #{limit} ms"}}
    end
  end

  defp served_before_copy?(%{server: %{}, copied_at: copied_at}, at), do: at < copied_at
  defp served_before_copy?(_shadow, _at), do: false

  # A server shadow takes its calls one at a time.
  defp next_queued(state, id) do
    with %{server: %{}, queue: queue} = s <- state.shadows[id],
         {{:value, {fun, args, live}}, rest} <- :queue.out(queue) do
      state = put_in(state.shadows[id], %{s | queue: rest})
      maybe_run(state, id, fun, args, live, nil)
    else
      _ -> state
    end
  end

  # The candidate's process died: the calls after it would all fail, so the
  # shadow ends with what it has.
  defp server_down(state, ref) do
    case Enum.find(state.shadows, fn {_id, s} -> match?(%{ref: ^ref}, s.server) end) do
      {id, _s} -> finish(state, id, true)
      nil -> state
    end
  end

  defp maybe_run(state, id, fun, args, live, source) do
    s = state.shadows[id]
    in_flight = Enum.count(state.workers, fn {_ref, w} -> w.id == id end)
    limit = if s && s.server, do: 1, else: @max_in_flight

    cond do
      s != nil and s.server != nil and in_flight >= 1 and s.started < s.calls ->
        if :queue.len(s.queue) < @max_queued,
          do: put_in(state.shadows[id], %{s | queue: :queue.in({fun, args, live}, s.queue)}),
          else: state

      s != nil and s.started < s.calls and in_flight < limit ->
        run(state, s, id, fun, args, live, source)

      true ->
        state
    end
  end

  defp run(state, s, id, fun, args, live, source) do
    {module, unit, signature} = {s.module, s.unit, s.signature}

    {pid, ref} =
      spawn_monitor(fn ->
        Theseus.Call.untraced!()

        if Behaviour.removed?(module, fun, args) do
          exit({:shadow_result, {:error, :removed}, :removed})
        else
          after_ = on_source(source, fn -> Behaviour.invoke(module, fun, args) end)
          target? = Behaviour.target?(signature, unit, fun, args, live)
          class = Behaviour.classify_call(live, after_, equivalence(unit), target?)
          exit({:shadow_result, after_, class})
        end
      end)

    worker = %{
      id: id,
      pid: pid,
      unit: s.unit,
      signature: s.signature,
      fun: fun,
      args: args,
      live: live,
      timer: Process.send_after(self(), {:too_slow, ref}, @call_timeout_ms)
    }

    state
    |> put_in([:workers, ref], worker)
    |> put_in([:shadows, id, :started], s.started + 1)
  end

  # An endpoint candidate reads what the live call read. A snapshot is
  # taken in a read-only transaction, which is rolled back; the live call
  # waits for it until told.
  defp on_source(nil, fun), do: fun.()

  defp on_source({{:snapshot, snapshot, tables, call}, to, ref}, fun) do
    result =
      try do
        Postgrex.transaction(
          Theseus.Store.ShadowPool,
          fn conn ->
            Postgrex.query!(
              conn,
              "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
              []
            )

            Postgrex.query!(conn, "SET TRANSACTION SNAPSHOT '#{snapshot}'", [])
            send(to, {ref, :imported})
            Postgrex.query!(conn, "SET LOCAL statement_timeout = #{@call_timeout_ms}", [])
            Theseus.Store.enter_shadow({:pg, conn, tables}, call)
            DBConnection.rollback(conn, {:shadowed, fun.()})
          end,
          timeout: @call_timeout_ms * 2
        )
      rescue
        e -> {:error, {:not_imported, Exception.message(e)}}
      catch
        :exit, why -> {:error, {:not_imported, inspect(why)}}
      end

    case result do
      {:error, {:shadowed, after_}} ->
        after_

      {:error, {:not_imported, why}} ->
        send(to, {ref, :imported})
        exit({:shadow_skipped, why})
    end
  end

  defp on_source({{context, call}, to, ref}, fun) do
    send(to, {ref, :imported})
    Theseus.Store.enter_shadow(context, call)
    fun.()
  end

  # Read in the worker, never kept here: a fun from the live spec module
  # held by this process would count as old code when the spec changes.
  defp equivalence(unit), do: (Registry.spec(unit) || %Spec{unit: unit}).equivalence

  defp item(worker, {:shadow_result, after_, class}),
    do: %{fun: worker.fun, args: worker.args, before: worker.live, after: after_, class: class}

  defp item(worker, reason) do
    after_ =
      if reason == :killed,
        do: {:error, {:exit, "took longer than #{@call_timeout_ms} ms"}},
        else: {:error, {:exit, reason}}

    target? =
      Behaviour.target?(worker.signature, worker.unit, worker.fun, worker.args, worker.live)

    %{
      fun: worker.fun,
      args: worker.args,
      before: worker.live,
      after: after_,
      class: Behaviour.classify_call(worker.live, after_, &==/2, target?)
    }
  end

  defp redact(item),
    do: %{
      item
      | args: Redact.term(item.args),
        before: Redact.term(item.before),
        after: Redact.term(item.after)
    }

  defp finish(state, id, report?) do
    case Map.pop(state.shadows, id) do
      {nil, _} ->
        state

      {s, shadows} ->
        :ets.match_delete(@table, {s.unit, id, :_})
        mirror()
        Process.cancel_timer(s.timer)

        {mine, others} = Enum.split_with(state.workers, fn {_ref, w} -> w.id == id end)

        for {ref, w} <- mine do
          Process.demonitor(ref, [:flush])
          Process.cancel_timer(w.timer)
          Process.exit(w.pid, :kill)
        end

        with %{pid: pid, ref: ref} <- s.server do
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
        end

        Validator.purge(s.module)
        if report?, do: Theseus.Changes.shadowed(id, stage(s))
        %{state | shadows: shadows, workers: Map.new(others)}
    end
  end

  defp stage(s) do
    ms = System.monotonic_time(:millisecond) - s.started_at
    summary = s.items |> Enum.reverse() |> Behaviour.summary()

    {result, detail} =
      cond do
        summary.compared == 0 ->
          {:skip, %{reason: "no live calls arrived in #{duration(s.ms)}"}}

        s.signature != nil ->
          {if(summary.differ == 0, do: :pass, else: :fail), summary}

        s.behaviour_change ->
          {:info, summary}

        summary.differ == 0 ->
          {:pass, summary}

        true ->
          {:fail, summary}
      end

    %{name: :shadow, result: result, detail: detail, ms: ms}
  end

  defp duration(ms) when ms < 1000, do: "#{ms} ms"
  defp duration(ms), do: "#{div(ms, 1000)} s"
end
