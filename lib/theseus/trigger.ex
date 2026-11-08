defmodule Theseus.Trigger do
  @moduledoc """
  Production mode: turns crashes of registered units into repair attempts,
  with no person present.

  Crashes arrive two ways: exceptions inside `Theseus.call/3` (telemetry
  event `[:theseus, :unit, :exception]`) and crashes of server unit
  processes (a `:logger` handler on `{:gen_server, :terminate}` reports).
  Crashes in `Theseus.*` code, including the proposer, are ignored.

  Each crash gets a `Theseus.Signature`. Per signature:

    * The first crash opens a window (`:window_ms`, default 10 s) that
      collects more failing calls, then one proposer run starts.
    * At most `:max_attempts` runs (default 2); after that, or when a fix
      fails, the signature is marked as needing a person and the proposer
      stops for it until a person allows another attempt.
    * At most `:runs_per_minute` runs overall (default 3).
    * A promoted fix is observed: the call that crashed is run again on the
      live unit, then a watch window (`:watch_ms`, default 5 minutes)
      starts. A crash with the same signature in the window rolls the fix
      back and marks the signature.

  Crash repair needs a model (`Theseus.LLM.available?/0`) and config
  `:crash_repair, :enabled` (default true). Without them crashes are still
  recorded. Attempts and marks are ledger events, so they survive restarts;
  a watch window does not.
  """

  use GenServer
  require Logger

  alias Theseus.{Change, Ledger, Loader, LLM, Proposer, Redact, Registry, Signature}

  @handler_id "theseus-trigger"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every known crash signature with its status, newest first."
  @spec list() :: [map()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Allows new repair attempts for a signature marked as needing a person."
  @spec retry(String.t(), term()) :: :ok | {:error, :not_found}
  def retry(id, actor \\ :human), do: GenServer.call(__MODULE__, {:retry, id, actor})

  @doc """
  Marks a signature resolved, for a crash a person dealt with some other
  way (a change of their own, say). It leaves the dashboard; if it happens
  again it opens again.
  """
  @spec resolve(String.t(), term()) :: :ok | {:error, :not_found | :busy}
  def resolve(id, actor \\ :human), do: GenServer.call(__MODULE__, {:resolve, id, actor})

  @doc false
  # From `Theseus.Changes` when a crash fix is held, promoted or rejected.
  def decided(%Change{} = change), do: GenServer.cast(__MODULE__, {:decided, change})

  @doc false
  def handle_telemetry(_event, _measurements, meta, _config) do
    GenServer.cast(
      __MODULE__,
      {:crash,
       %{
         kind: :call,
         unit: meta.unit,
         fun: meta.fun,
         arity: length(meta.args),
         args: meta.args,
         error: meta.error,
         stacktrace: meta.stacktrace
       }}
    )
  end

  defp setting(key, default),
    do: Application.get_env(:theseus, :crash_repair, []) |> Keyword.get(key, default)

  ## Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(
        @handler_id,
        [:theseus, :unit, :exception],
        &__MODULE__.handle_telemetry/4,
        nil
      )

    :logger.remove_handler(:theseus_trigger)
    :ok = :logger.add_handler(:theseus_trigger, Theseus.Trigger.LogHandler, %{level: :error})

    {:ok, %{sigs: rebuild(), runs: [], tasks: %{}}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :logger.remove_handler(:theseus_trigger)
  end

  @impl true
  def handle_call(:list, _from, state) do
    list =
      state.sigs
      |> Map.values()
      |> Enum.sort_by(& &1.last_at, {:desc, DateTime})
      |> Enum.map(&Map.drop(&1, [:timer, :crash]))

    {:reply, list, state}
  end

  def handle_call({:resolve, id, actor}, _from, state) do
    case state.sigs[id] do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status in [:collecting, :proposing, :held, :watching] ->
        {:reply, {:error, :busy}, state}

      s ->
        record(s, {:signature_marked, id, :resolved, "a person marked it resolved"}, actor)
        s = %{s | status: :resolved, note: "marked resolved"}
        {:reply, :ok, put(state, s)}
    end
  end

  def handle_call({:retry, id, actor}, _from, state) do
    case state.sigs[id] do
      nil ->
        {:reply, {:error, :not_found}, state}

      s ->
        cancel(s)
        record(s, {:signature_marked, id, :cleared, "a person allowed new attempts"}, actor)
        s = %{s | status: :idle, attempts: 0, timer: nil, watch: nil}
        {:reply, :ok, put(state, s)}
    end
  end

  @impl true
  def handle_cast({:crash, crash}, state) do
    with true <- setting(:enabled, true),
         {:ok, kind} <- unit_kind(crash.unit),
         false <- duplicate_of_server_crash?(crash, kind) do
      signature = Signature.of(crash.unit, crash.fun, crash.arity, crash.error)
      crash = crash |> Map.delete(:unit) |> Redact.term() |> Map.put(:at, DateTime.utc_now())
      {:noreply, on_crash(state, signature, crash)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_cast(
        {:decided, %Change{trigger: %{payload: %{signature: %{id: id}}}} = change},
        state
      ) do
    case state.sigs[id] do
      nil -> {:noreply, state}
      s -> {:noreply, on_decided(state, s, change)}
    end
  end

  @impl true
  def handle_info({:window_closed, id}, state) do
    case state.sigs[id] do
      %{status: :collecting} = s -> {:noreply, start_run(state, s)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:watch_over, id}, state) do
    case state.sigs[id] do
      %{status: :watching} = s -> {:noreply, put(state, %{s | status: :fixed, watch: nil})}
      _ -> {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {id, tasks} = Map.pop(state.tasks, ref)
    state = %{state | tasks: tasks}
    s = state.sigs[id]

    case result do
      {:ok, %Change{} = change} -> {:noreply, on_run_result(state, s, change)}
      {:error, reason} -> {:noreply, failed(state, s, reason)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tasks, ref) do
    {id, tasks} = Map.pop(state.tasks, ref)
    state = %{state | tasks: tasks}
    {:noreply, failed(state, state.sigs[id], {:proposer_crashed, reason})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Crashes

  defp unit_kind(unit) do
    name = Atom.to_string(unit)

    with false <- String.starts_with?(name, "Elixir.Theseus."),
         {:ok, %{kind: kind}} when kind in [:pure, :server, :endpoint, :store] <-
           Registry.fetch(unit) do
      {:ok, kind}
    else
      _ -> :ignore
    end
  end

  # A caller sees a server's crash as an exit; the server's own crash
  # report is the one to act on.
  defp duplicate_of_server_crash?(%{kind: :call, error: {:exit, _}}, :server), do: true
  defp duplicate_of_server_crash?(_crash, _kind), do: false

  defp on_crash(state, signature, crash) do
    now = DateTime.utc_now()

    {s, new?} =
      case state.sigs[signature.id] do
        nil -> {new_sig(signature, now), true}
        s -> {%{s | count: s.count + 1, last_at: now}, false}
      end

    if new?, do: record(s, {:crash_seen, signature, summary(crash)}, :trigger)

    # A crash marked resolved that happens again opens again.
    s =
      if s.status == :resolved do
        record(
          s,
          {:signature_marked, s.id, :cleared, "it happened again after being marked resolved"},
          :trigger
        )

        %{s | status: :idle, attempts: 0, note: "happened again after being marked resolved"}
      else
        s
      end

    cond do
      s.status == :watching ->
        rollback(state, s, "it crashed again with the same signature during the watch window")

      s.status not in [:idle, :fixed] ->
        put(state, s)

      s.attempts >= setting(:max_attempts, 2) ->
        mark(state, s, "#{s.attempts} repair attempts did not fix it")

      not LLM.available?() ->
        if new?, do: Logger.warning("crash repair is off: #{LLM.name()} is not available")
        put(state, s)

      true ->
        timer = Process.send_after(self(), {:window_closed, s.id}, setting(:window_ms, 10_000))
        put(state, %{s | status: :collecting, crash: crash, timer: timer})
    end
  end

  defp new_sig(signature, now) do
    %{
      id: signature.id,
      signature: signature,
      status: :idle,
      count: 1,
      attempts: 0,
      first_at: now,
      last_at: now,
      crash: nil,
      timer: nil,
      watch: nil,
      change_id: nil,
      note: nil
    }
  end

  defp summary(crash) do
    %{
      call: "#{crash.fun}/#{crash.arity}",
      error: Theseus.Describe.text(crash.error) |> String.slice(0, 300)
    }
  end

  ## Proposer runs

  defp start_run(state, s) do
    now = System.monotonic_time(:millisecond)
    runs = Enum.filter(state.runs, &(&1 > now - 60_000))

    if length(runs) >= setting(:runs_per_minute, 3) do
      wait = hd(Enum.sort(runs)) + 60_000 - now
      timer = Process.send_after(self(), {:window_closed, s.id}, max(wait, 100))
      put(%{state | runs: runs}, %{s | timer: timer})
    else
      attempt = s.attempts + 1
      record(s, {:repair_started, s.id, attempt}, :trigger)

      if attempt == 1,
        do: Theseus.Notices.repair_started(Theseus.Signature.describe_short(s.signature))

      task =
        Task.Supervisor.async_nolink(Theseus.ProposerSupervisor, Proposer, :fix, [
          %{signature: s.signature, attempt: attempt, crash: s.crash}
        ])

      state = %{state | runs: [now | runs], tasks: Map.put(state.tasks, task.ref, s.id)}
      put(state, %{s | status: :proposing, attempts: attempt, timer: nil})
    end
  end

  defp on_run_result(state, s, %Change{status: :promoted} = change), do: watch(state, s, change)

  defp on_run_result(state, s, %Change{status: :held, id: id}),
    do: put(state, %{s | status: :held, change_id: id})

  defp on_run_result(state, s, %Change{status: :rejected} = change),
    do: failed(state, s, {:rejected, change.id})

  defp on_run_result(state, s, change), do: put(state, %{s | change_id: change.id})

  # While a run is going, its own result decides; later decisions are a
  # person's.
  defp on_decided(state, %{status: :proposing}, _change), do: state

  defp on_decided(state, s, %Change{status: :promoted} = change) do
    if s.watch && s.watch.change_id == change.id, do: state, else: watch(state, s, change)
  end

  defp on_decided(state, s, %Change{status: :held, id: id}),
    do: put(state, %{s | status: :held, change_id: id})

  defp on_decided(state, %{status: :held} = s, %Change{status: :rejected} = change),
    do: failed(state, s, {:rejected, change.id})

  defp on_decided(state, _s, _change), do: state

  defp failed(state, s, reason) do
    record(s, {:repair_failed, s.id, s.attempts, describe(reason)}, :trigger)

    if s.attempts >= setting(:max_attempts, 2),
      do: mark(state, s, "#{s.attempts} repair attempts did not fix it"),
      else: put(state, %{s | status: :idle})
  end

  defp describe({:rejected, id}), do: "#{id} was rejected"
  defp describe(reason), do: Theseus.Describe.text(reason)

  ## Watching a promoted fix

  defp watch(state, s, %Change{} = change) do
    %{hash: hash, parent: parent} = Change.unit_candidate(change)
    s = %{s | change_id: change.id, watch: %{change_id: change.id, hash: hash, parent: parent}}

    if crashes_again?(s) do
      rollback(state, s, "the call that crashed still crashes after the fix")
    else
      timer = Process.send_after(self(), {:watch_over, s.id}, setting(:watch_ms, 300_000))
      put(state, %{s | status: :watching, timer: timer})
    end
  end

  # Runs the call that crashed once more against the live unit.
  defp crashes_again?(%{crash: %{kind: :call, fun: fun, args: args}, signature: sig}) do
    task =
      Task.Supervisor.async_nolink(Theseus.TaskSupervisor, fn ->
        try do
          apply(sig.unit, fun, args)
          false
        catch
          :error, reason ->
            error = Exception.normalize(:error, reason, __STACKTRACE__)
            Signature.matches?(sig, sig.unit, fun, length(args), error)

          kind, reason ->
            Signature.matches?(sig, sig.unit, fun, length(args), {kind, reason})
        end
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, crashed?} -> crashed?
      _ -> true
    end
  end

  defp crashes_again?(_s), do: false

  defp rollback(state, s, reason) do
    cancel(s)
    unit = s.signature.unit

    with %{hash: hash, parent: parent} <- s.watch,
         {:ok, %{current_version: ^hash}} <- Registry.fetch(unit) do
      case Loader.rollback(unit, parent, actor: :system, reason: "#{s.change_id}: #{reason}") do
        {:ok, _} -> :ok
        {:error, why} -> Logger.error("could not roll back #{inspect(unit)}: #{inspect(why)}")
      end
    end

    mark(state, %{s | watch: nil}, reason)
  end

  defp mark(state, s, reason) do
    cancel(s)
    record(s, {:signature_marked, s.id, :needs_human, reason}, :trigger)

    Logger.warning("crash #{Signature.describe_short(s.signature)} needs a person: #{reason}")

    put(state, %{s | status: :needs_human, timer: nil, note: reason})
  end

  ## Helpers

  defp put(state, s), do: %{state | sigs: Map.put(state.sigs, s.id, s)}

  defp cancel(%{timer: nil}), do: :ok
  defp cancel(%{timer: timer}), do: Process.cancel_timer(timer)

  defp record(s, body, actor) do
    {:ok, _} = Ledger.append(body, actor: actor, unit: s.signature.unit)
  end

  # Signatures, attempts and marks from the ledger. A held crash fix keeps
  # its signature held; a promoted one counts as fixed (a watch window does
  # not survive a restart).
  defp rebuild do
    sigs =
      Enum.reduce(Ledger.events(), %{}, fn
        %{body: {:crash_seen, %Signature{} = sig, _}, at: at}, acc ->
          Map.update(acc, sig.id, new_sig(sig, at), &%{&1 | count: &1.count + 1, last_at: at})

        %{body: {:repair_started, id, attempt}}, acc ->
          update(acc, id, &%{&1 | attempts: attempt})

        %{body: {:signature_marked, id, :needs_human, reason}}, acc ->
          update(acc, id, &%{&1 | status: :needs_human, note: reason})

        %{body: {:signature_marked, id, :cleared, _}}, acc ->
          update(acc, id, &%{&1 | status: :idle, attempts: 0, note: nil})

        %{body: {:signature_marked, id, :resolved, _}}, acc ->
          update(acc, id, &%{&1 | status: :resolved, note: "marked resolved"})

        _event, acc ->
          acc
      end)

    # Oldest first, so the newest decision wins.
    for {%Change{trigger: %{kind: :crash, payload: %{signature: %{id: id}}}} = c, _} <-
          Enum.reverse(Theseus.Changes.list(limit: :all)),
        c.status in [:held, :promoted],
        reduce: sigs do
      acc ->
        update(acc, id, fn
          %{status: status} = s when status in [:needs_human, :resolved] -> s
          s -> %{s | status: if(c.status == :held, do: :held, else: :fixed), change_id: c.id}
        end)
    end
  end

  defp update(sigs, id, fun) do
    case sigs do
      %{^id => s} -> Map.put(sigs, id, fun.(s))
      _ -> sigs
    end
  end
end

defmodule Theseus.Trigger.LogHandler do
  @moduledoc false
  # A `:logger` handler: hands crash reports of server unit processes to
  # `Theseus.Trigger`. Runs in the crashing process, so it does little.

  def log(%{msg: {:report, %{label: {:gen_server, :terminate}, name: name} = report}}, _config)
      when is_atom(name) do
    case report[:reason] do
      # A unit the server's callback called already reported this crash.
      {raw, _stacktrace} ->
        unless Theseus.Call.reported_here?(raw), do: server_crash(name, report)

      _ ->
        server_crash(name, report)
    end
  catch
    _, _ -> :ok
  end

  def log(_event, _config), do: :ok

  defp server_crash(name, report) do
    {error, stacktrace} =
      case report[:reason] do
        {raw, stacktrace} when is_list(stacktrace) ->
          {Exception.normalize(:error, raw, stacktrace), stacktrace}

        other ->
          {{:exit, other}, []}
      end

    {fun, arity} =
      Enum.find_value(stacktrace, {:unknown, 0}, fn
        {^name, fun, arity, _} -> {fun, if(is_list(arity), do: length(arity), else: arity)}
        _ -> nil
      end)

    GenServer.cast(
      Theseus.Trigger,
      {:crash,
       %{
         kind: :server,
         unit: name,
         fun: fun,
         arity: arity,
         args: [report[:last_message]],
         state: report[:state],
         error: error,
         stacktrace: stacktrace
       }}
    )
  end
end
