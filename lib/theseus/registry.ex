defmodule Theseus.Registry do
  @moduledoc """
  The live view of registered units and specs: which version of each is
  loaded. It is a cache of the ledger fold for the live branch, rebuilt at
  boot and when the live branch is switched. Reads come straight from ETS.
  """

  use GenServer

  alias Theseus.{Spec, Unit}

  @units :theseus_units

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(Unit.t()) :: :ok
  def put(%Unit{} = unit), do: GenServer.call(__MODULE__, {:put, unit})

  @spec delete(module()) :: :ok
  def delete(module), do: GenServer.call(__MODULE__, {:delete, module})

  @spec set_current(module(), String.t()) :: :ok
  def set_current(module, hash), do: GenServer.call(__MODULE__, {:set_current, module, hash})

  @spec fetch(module()) :: {:ok, Unit.t()} | :error
  def fetch(module) do
    case :ets.lookup(@units, module) do
      [{_, u}] -> {:ok, u}
      [] -> :error
    end
  end

  @spec fetch!(module()) :: Unit.t()
  def fetch!(module) do
    case fetch(module) do
      {:ok, u} -> u
      :error -> raise ArgumentError, "#{inspect(module)} is not registered"
    end
  end

  @doc "Every registered application unit (not specs), sorted."
  @spec units() :: [Unit.t()]
  def units, do: Enum.reject(all(), &(&1.kind == :spec))

  @doc "Every registered module, units and specs, sorted."
  @spec all() :: [Unit.t()]
  def all, do: @units |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.module)

  @doc "The live spec of a unit, or nil."
  @spec spec(module()) :: Spec.t() | nil
  def spec(unit) do
    with {:ok, %Unit{spec: spec_module}} when spec_module != nil <- fetch(unit),
         {:ok, %Unit{kind: :spec}} <- fetch(spec_module) do
      spec_module.__spec__()
    else
      _ -> nil
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@units, [:set, :named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, unit}, _from, state) do
    :ets.insert(@units, {unit.module, unit})
    {:reply, :ok, state}
  end

  def handle_call({:delete, module}, _from, state) do
    :ets.delete(@units, module)
    {:reply, :ok, state}
  end

  def handle_call({:set_current, module, hash}, _from, state) do
    [{_, u}] = :ets.lookup(@units, module)
    :ets.insert(@units, {module, %{u | current_version: hash}})
    {:reply, :ok, state}
  end
end
