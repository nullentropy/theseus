defmodule Theseus.Servers do
  @moduledoc """
  Runs the live branch's server units. Each server unit is started with
  `start_link([])` when the app boots, when an approved change creates it,
  and when a branch switch brings it in; it is stopped when a switch takes
  it out. A crashing server unit is restarted, like any supervised process.
  Each start puts the process on its saved state (`Theseus.State`), so a
  restart after a crash or a reboot carries on where it was.
  """

  use DynamicSupervisor
  require Logger

  alias Theseus.Registry

  @table __MODULE__

  def start_link(opts \\ []) do
    with {:ok, pid} <- DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      for %{kind: :server, module: module} <- Registry.units(), do: start(module)
      {:ok, pid}
    end
  end

  @impl true
  def init(_opts) do
    # module => {pid, restored?}. Written by the start function, which runs
    # in this process, so the table lives as long as the supervisor.
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10)
  end

  @doc "Starts a server unit's process, unless it is running."
  @spec start(module()) :: :ok | {:error, term()}
  def start(module) do
    if match?({:ok, _}, pid(module)) do
      :ok
    else
      spec = %{id: module, start: {__MODULE__, :start_unit, [module]}, restart: :permanent}

      case DynamicSupervisor.start_child(__MODULE__, spec) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} = error ->
          Logger.error("could not start #{inspect(module)}: #{inspect(reason)}")
          error
      end
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  # The child's start function: starts the unit and puts it on its saved state.
  def start_unit(module) do
    with {:ok, pid} <- module.start_link([]) do
      restored = Theseus.State.restore(module, pid)
      :ets.insert(@table, {module, pid, restored != :not_running})
      {:ok, pid}
    end
  end

  @doc "Stops a server unit's process."
  @spec stop(module()) :: :ok
  def stop(module) do
    with {:ok, pid} <- pid(module) do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    :ets.delete(@table, module)
    :ok
  end

  @doc "The running process of a server unit."
  @spec pid(module()) :: {:ok, pid()} | :error
  def pid(module) do
    case lookup(module) do
      [{^module, pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      _ -> :error
    end
  end

  @doc "Every running server unit, as `{module, pid}`."
  @spec running() :: [{module(), pid()}]
  def running do
    if :ets.whereis(@table) == :undefined,
      do: [],
      else: for({m, pid, _} <- :ets.tab2list(@table), Process.alive?(pid), do: {m, pid})
  end

  @doc false
  # Server units started before Theseus.State loaded the state file.
  def unrestored do
    if :ets.whereis(@table) == :undefined,
      do: [],
      else: for({m, pid, false} <- :ets.tab2list(@table), Process.alive?(pid), do: {m, pid})
  end

  @doc false
  def restored(module, pid), do: :ets.insert(@table, {module, pid, true})

  defp lookup(module) do
    if :ets.whereis(@table) == :undefined, do: [], else: :ets.lookup(@table, module)
  end
end
