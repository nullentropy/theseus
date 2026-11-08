defmodule Theseus.TraceFile do
  @moduledoc """
  Recorded calls on disk, encrypted, so the replay set survives a restart.
  The file is not part of the application: deleting it loses only evidence.

  A `Theseus.SealedLog` with magic `THESEUST` whose records are
  `%Theseus.Trace{}` structs, redacted before they get here. The key is the
  trace key (`Theseus.Keys`), never stored next to the file. A file written
  with another key cannot be read; it is moved aside to
  `<path>.unreadable-<time>` and recording starts again.
  """

  alias Theseus.{SealedLog, Trace}

  @magic "THESEUST"

  @type t :: SealedLog.t()

  @doc """
  The trace file's path: config `:trace_path`, or the ledger's path plus
  `.traces`. A node that may run beside others on the same ledger (see
  `Theseus.Leader`) keeps its own, `<ledger>.<node>.traces`.
  """
  @spec path() :: Path.t()
  def path do
    ledger = Application.fetch_env!(:theseus, :ledger_path)

    cond do
      path = Application.get_env(:theseus, :trace_path) -> path
      Node.alive?() and Theseus.Records.database?() -> "#{ledger}.#{node()}.traces"
      true -> ledger <> ".traces"
    end
  end

  @doc """
  The path to open: `path/0`, after the leader takes over the file a node
  kept before it ran beside others, `<ledger>.traces`, so the calls it
  recorded stay.
  """
  @spec adopt() :: Path.t()
  def adopt do
    path = path()
    plain = Application.fetch_env!(:theseus, :ledger_path) <> ".traces"

    if path != plain and Theseus.Leader.leader?() and File.exists?(plain) and
         not File.exists?(path),
       do: File.rename!(plain, path)

    path
  end

  @doc "Opens the file, creating it if needed. Returns the traces in it, oldest first."
  @spec open(Path.t(), binary()) :: {t(), [Trace.t()]}
  def open(path, key), do: SealedLog.open(path, key, @magic)

  @spec append(t(), Trace.t()) :: :ok
  def append(file, %Trace{} = trace), do: SealedLog.append(file, trace)

  @doc "Replaces the file's contents with `traces`, through a temporary file."
  @spec rewrite(t(), [Trace.t()]) :: t()
  def rewrite(file, traces), do: SealedLog.rewrite(file, traces)

  @spec close(t()) :: :ok
  def close(file), do: SealedLog.close(file)

  @doc "The encryption key (`Theseus.Keys.trace/0`)."
  @spec key() :: binary()
  def key, do: Theseus.Keys.trace()
end
