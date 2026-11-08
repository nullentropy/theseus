defmodule Theseus.Sandbox do
  @moduledoc """
  Runs candidate code on a separate BEAM node, so compile-time side effects,
  runaway loops and memory blowups cannot reach the live VM.

  Each run starts a fresh node with `:peer` (about 0.1 s), connected over
  its standard input and output rather than Erlang distribution, so the live
  node does not need to be distributed and the sandbox cannot reach it. The
  node has the same code paths as the live node, and is stopped when the
  run ends, times out or the caller exits.
  """

  @doc """
  Calls `module.fun(args...)` on a fresh node. Returns `{:ok, result}` or
  `{:error, reason}`; the node is stopped either way.
  """
  @spec run(module(), atom(), [term()], pos_integer()) :: {:ok, term()} | {:error, String.t()}
  def run(module, fun, args, timeout) do
    # The node is linked to the process that starts it. That process is a
    # task, so a node that dies takes the task down, not the caller.
    task =
      Task.Supervisor.async_nolink(Theseus.TaskSupervisor, fn ->
        run_here(module, fun, args, timeout)
      end)

    case Task.yield(task, timeout + 40_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "the sandbox node stopped: #{inspect(reason, limit: 10)}"}
      nil -> {:error, "the sandbox node did not answer within #{timeout} ms"}
    end
  end

  defp run_here(module, fun, args, timeout) do
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: code_path() ++ [~c"-noinput"],
        wait_boot: 30_000
      })

    try do
      :ok = :peer.call(peer, __MODULE__, :prepare, [], 30_000)
      {:ok, :peer.call(peer, module, fun, args, timeout)}
    catch
      kind, reason -> {:error, describe_failure(kind, reason, timeout)}
    after
      :peer.stop(peer)
    end
  end

  @doc false
  # Runs on the sandbox node: starts Elixir and sends all output, including
  # compiler warnings, nowhere.
  def prepare do
    {:ok, _} = Application.ensure_all_started(:elixir)
    :logger.set_primary_config(:level, :none)
    sink = spawn(&sink/0)

    with pid when is_pid(pid) <- Process.whereis(:standard_error) do
      Process.unregister(:standard_error)
    end

    Process.register(sink, :standard_error)
    :persistent_term.put({__MODULE__, :sink}, sink)
    :ok
  end

  @doc false
  # On the sandbox node: an IO device that accepts and drops everything.
  def sink_device, do: :persistent_term.get({__MODULE__, :sink})

  defp sink do
    receive do
      {:io_request, from, reply_as, request} ->
        send(from, {:io_reply, reply_as, sink_reply(request)})

      _ ->
        :ok
    end

    sink()
  end

  defp sink_reply({:put_chars, _, _}), do: :ok
  defp sink_reply({:put_chars, _, _, _, _}), do: :ok
  defp sink_reply({:put_chars, _}), do: :ok
  defp sink_reply({:requests, _}), do: :ok
  defp sink_reply(_), do: {:error, :enotsup}

  defp code_path, do: Enum.flat_map(:code.get_path() -- [~c"."], &[~c"-pa", &1])

  defp describe_failure(:exit, reason, timeout) do
    if timeout_reason?(reason),
      do: "the sandbox node did not answer within #{timeout} ms",
      else: "the sandbox node stopped: #{inspect(reason, limit: 10)}"
  end

  defp describe_failure(kind, reason, _timeout),
    do: "the sandbox run failed: #{kind} #{inspect(reason, limit: 10)}"

  defp timeout_reason?(:timeout), do: true
  defp timeout_reason?({:timeout, _}), do: true
  defp timeout_reason?(_), do: false
end
