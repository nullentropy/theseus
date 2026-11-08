defmodule Theseus.Call do
  @moduledoc """
  The only way application code invokes a unit. Records a trace of every
  call, hands the call to a running shadow (see `Theseus.Shadow`), and
  re-raises anything the unit raises. A raise also emits the telemetry event
  `[:theseus, :unit, :exception]`, which `Theseus.Trigger` listens to.

  On a follower (`Theseus.Leader`), a server unit's call runs on the leader,
  and crashes are reported to the leader.
  """

  alias Theseus.{Registry, Shadow, Trace, Traces}

  @spec call(module(), atom(), [term()]) :: term()
  def call(unit, fun, args) when is_atom(unit) and is_atom(fun) and is_list(args) do
    cond do
      :persistent_term.get({__MODULE__, :sandbox}, false) -> apply(unit, fun, args)
      Process.get({__MODULE__, :untraced}, false) -> apply(unit, fun, args)
      true -> traced(unit, fun, args)
    end
  end

  @doc false
  # On a sandbox node there is no registry or trace store: an endpoint
  # unit under validation calls the branch's units directly.
  def sandbox!, do: :persistent_term.put({__MODULE__, :sandbox}, true)

  @doc false
  # A shadowed candidate runs in processes marked with this. Its calls to
  # other units apply directly: they are not recorded, not handed to other
  # shadows and not reported as crashes, since nobody made them.
  def untraced!, do: Process.put({__MODULE__, :untraced}, true)

  defp traced(unit, fun, args) do
    {version, kind} =
      case Registry.fetch!(unit) do
        %{kind: :spec} -> raise ArgumentError, "#{inspect(unit)} is a spec, not a callable unit"
        record -> {record.current_version, record.kind}
      end

    if kind == :server, do: Theseus.Store.server_called()

    if kind == :server and Theseus.Leader.follower?(),
      do: on_leader(unit, fun, args),
      else: run(unit, fun, args, version, kind)
  end

  # A server unit runs on the leader (see Theseus.Leader), and its call is
  # recorded and reported there, so the calls around it here do not report
  # it again.
  defp on_leader(unit, fun, args) do
    leader = Theseus.Leader.node() || raise "no leader to call #{inspect(unit)} on"

    try do
      :erpc.call(leader, __MODULE__, :call, [unit, fun, args], :infinity)
    catch
      :error, {:exception, reason, stacktrace} ->
        if Process.get({__MODULE__, :depth}, 0) > 0,
          do: Process.put({__MODULE__, :reported}, {:error, reason, stacktrace})

        :erlang.raise(:error, reason, stacktrace)

      :exit, {:exception, reason} ->
        exit(reason)
    end
  end

  defp run(unit, fun, args, version, kind) do
    depth = Process.get({__MODULE__, :depth}, 0)
    Process.put({__MODULE__, :depth}, depth + 1)

    try do
      apply(unit, fun, args)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        error =
          case kind do
            :error -> Exception.normalize(:error, reason, stacktrace)
            _ -> {kind, reason}
          end

        record(unit, fun, args, {:error, error, stacktrace}, version)
        Shadow.tee(unit, fun, args, {:error, error})

        report(unit, fun, args, error, {kind, reason, stacktrace}, depth > 0)

        :erlang.raise(kind, reason, stacktrace)
    else
      result ->
        record(unit, fun, args, {:ok, result}, version)
        Shadow.tee(unit, fun, args, {:ok, result})
        result
    after
      Process.put({__MODULE__, :depth}, depth)
      if kind == :server, do: Theseus.State.touch(unit)
    end
  end

  # A crash is reported once, by the unit it happened in. When an endpoint
  # unit's call to another unit raises, the same exception passes through
  # the endpoint's own call on the way out; that one is not reported again.
  #
  # The mark stays until the outermost call, however deep the calls go. The
  # outermost report also leaves its reason for a moment, so the crash log
  # of a server unit whose callback raised it is not a second report (see
  # `reported_here?/1`).
  defp report(unit, fun, args, error, raised, nested?) do
    key = {__MODULE__, :reported}

    if Process.get(key) == raised do
      unless nested?, do: Process.delete(key)
    else
      if nested?, do: Process.put(key, raised)
      {_kind, reason, _stacktrace} = raised
      Process.put({__MODULE__, :last_report}, {reason, System.monotonic_time(:millisecond)})

      emit(%{unit: unit, fun: fun, args: args, error: error, stacktrace: elem(raised, 2)})
    end
  end

  # Crash repair runs on the leader: a follower's crashes go there.
  defp emit(meta) do
    event = [:theseus, :unit, :exception]

    leader = Theseus.Leader.node()

    if Theseus.Leader.follower?() and leader != nil,
      do: :erpc.cast(leader, :telemetry, :execute, [event, %{}, meta]),
      else: :telemetry.execute(event, %{}, meta)
  end

  @doc false
  # Whether a unit call in this process reported this reason in the last few
  # seconds. The crash log handler runs in the crashing process and asks.
  def reported_here?(reason) do
    case Process.get({__MODULE__, :last_report}) do
      {^reason, at} -> System.monotonic_time(:millisecond) - at < 5_000
      _ -> false
    end
  end

  defp record(unit, fun, args, result, version) do
    Traces.record(%Trace{
      id: System.unique_integer([:positive, :monotonic]),
      unit: unit,
      fun: fun,
      args: args,
      result: result,
      version: version,
      at: DateTime.utc_now()
    })
  end
end
