defmodule Theseus.LedgerLock do
  @moduledoc """
  Keeps two Theseus instances from opening the same ledger. Two instances
  would append to one ledger and rewrite the files beside it (recorded
  calls, state, connections, outbox) under each other.

  The lock is a file next to the ledger, `<ledger>.lock`, created only if it
  does not exist. It holds the operating system process id of the Erlang VM
  that holds it, its node name and when it took the lock. A lock whose
  process is gone (the VM crashed or was killed) is taken over. A lock held
  by this same VM is kept, so the ledger process can restart. The lock is
  removed when the ledger process stops.
  """

  require Logger

  @doc "The lock file's path for a ledger."
  @spec path(Path.t()) :: Path.t()
  def path(ledger_path), do: ledger_path <> ".lock"

  @doc "Takes the lock for a ledger, or says who holds it."
  @spec acquire(Path.t()) :: :ok | {:error, String.t()}
  def acquire(ledger_path) do
    lock = path(ledger_path)

    case create(lock) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case holder(lock) do
          :me ->
            write(lock)

          {:running, pid, details} ->
            {:error,
             "#{ledger_path} is already open in another Theseus (OS process #{pid}#{details}). " <>
               "Stop that one first. If no Theseus is running, delete #{lock}."}

          :gone ->
            Logger.warning("taking over #{lock}, left by a Theseus that is no longer running")
            File.rm(lock)

            case create(lock) do
              :ok ->
                :ok

              {:error, _} ->
                {:error, "#{ledger_path} was opened by another Theseus just now. Stop it first."}
            end
        end

      {:error, reason} ->
        {:error, "could not create #{lock}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Removes the lock if this VM holds it."
  @spec release(Path.t()) :: :ok
  def release(ledger_path) do
    lock = path(ledger_path)
    if holder(lock) == :me, do: File.rm(lock)
    :ok
  end

  defp create(lock) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        IO.binwrite(io, contents())
        File.close(io)

      error ->
        error
    end
  end

  defp write(lock), do: File.write(lock, contents())

  defp contents do
    "#{System.pid()}\n#{node()}\n#{DateTime.to_iso8601(DateTime.utc_now())}\n"
  end

  # Who holds a lock: this VM, another running Erlang VM, or nobody alive.
  defp holder(lock) do
    case File.read(lock) do
      {:ok, text} ->
        case String.split(text, "\n") do
          [pid, node, since | _] -> classify(String.trim(pid), node, since)
          _ -> :gone
        end

      {:error, _} ->
        :gone
    end
  end

  defp classify(pid, node, since) do
    cond do
      not Regex.match?(~r/^\d+$/, pid) -> :gone
      pid == System.pid() -> :me
      erlang_vm?(pid) -> {:running, pid, describe(node, since)}
      true -> :gone
    end
  end

  defp describe(node, since) do
    node = if node in ["", "nonode@nohost"], do: "", else: ", node #{node}"
    since = if since == "", do: "", else: ", since #{since}"
    node <> since
  end

  # Only a running Erlang VM counts, so a process id reused by another
  # program after a reboot does not keep the lock.
  defp erlang_vm?(pid) do
    case System.cmd("ps", ["-o", "comm=", "-p", pid], stderr_to_stdout: true) do
      {out, 0} -> String.contains?(out, "beam")
      _ -> false
    end
  rescue
    # Without ps, assume it is running: refusing is safer than sharing.
    _ -> true
  end
end
