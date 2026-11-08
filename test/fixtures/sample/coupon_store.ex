defmodule Sample.CouponStore do
  use GenServer

  @defaults ["SAVE10", "FIVEOFF", "SHIPFREE"]

  def start_link(opts \\ []) do
    codes = Keyword.get(opts, :codes, @defaults)
    GenServer.start_link(__MODULE__, codes, name: Keyword.get(opts, :name, __MODULE__))
  end

  def active?(store \\ __MODULE__, code), do: GenServer.call(store, {:active?, code})
  def activate(store \\ __MODULE__, code), do: GenServer.call(store, {:activate, code})
  def deactivate(store \\ __MODULE__, code), do: GenServer.call(store, {:deactivate, code})
  def codes(store \\ __MODULE__), do: GenServer.call(store, :codes)

  @impl true
  def init(codes), do: {:ok, MapSet.new(codes)}

  @impl true
  def handle_call({:active?, code}, _from, codes),
    do: {:reply, MapSet.member?(codes, code), codes}

  def handle_call({:activate, code}, _from, codes), do: {:reply, :ok, MapSet.put(codes, code)}

  def handle_call({:deactivate, code}, _from, codes),
    do: {:reply, :ok, MapSet.delete(codes, code)}

  def handle_call(:codes, _from, codes),
    do: {:reply, codes |> MapSet.to_list() |> Enum.sort(), codes}

  @impl true
  def code_change(_old_vsn, codes, _extra), do: {:ok, codes}
end
