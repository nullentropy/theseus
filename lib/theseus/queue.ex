defmodule Theseus.Queue do
  @moduledoc """
  Sandbox slots for validations, shared fairly (step 5 of
  `docs/team-design.md`). Each validation starts a sandbox node; at most
  `slots` run at once (config `:validation, slots:`, by default half the
  schedulers and at least 2). The others wait, one queue per person, and a
  free slot goes to the next person in turn, so one busy agent cannot hold
  up everyone else. Validations the engine starts itself (crash repairs,
  consolidations, combined changes) queue as the engine.

  A process that already holds a slot runs again without waiting, so a
  validation inside a validation cannot wait for itself.
  """

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The number of validations that run at once."
  @spec slots() :: pos_integer()
  def slots do
    Keyword.get(
      Application.get_env(:theseus, :validation, []),
      :slots,
      max(2, div(System.schedulers_online(), 2))
    )
  end

  @doc """
  Runs `fun` once a slot is free, for `who` (a person's email address, or
  `:engine`). Records how long it waited, which `waited/0` returns.
  """
  @spec run(term(), (-> result)) :: result when result: term()
  def run(who, fun) do
    cond do
      Process.whereis(__MODULE__) == nil or Process.get({__MODULE__, :holding}) ->
        fun.()

      true ->
        started = System.monotonic_time(:millisecond)
        {:ok, ahead} = GenServer.call(__MODULE__, {:wait, who}, :infinity)

        Process.put({__MODULE__, :waited}, %{
          ms: System.monotonic_time(:millisecond) - started,
          ahead: ahead
        })

        Process.put({__MODULE__, :holding}, true)

        try do
          fun.()
        after
          Process.delete({__MODULE__, :holding})
          GenServer.cast(__MODULE__, {:done, self()})
        end
    end
  end

  @doc "How long this process's last validation waited for a slot, and how many were ahead of it."
  @spec waited() :: %{ms: non_neg_integer(), ahead: non_neg_integer()} | nil
  def waited, do: Process.get({__MODULE__, :waited})

  @doc "Running and waiting validations, by person."
  @spec status() :: %{slots: pos_integer(), running: [term()], waiting: [{term(), pos_integer()}]}
  def status, do: GenServer.call(__MODULE__, :status)

  ## Server

  @impl true
  def init(_opts), do: {:ok, %{running: %{}, waiting: %{}, turn: []}}

  @impl true
  def handle_call({:wait, who}, {pid, _} = from, state) do
    ahead = state.waiting |> Map.values() |> Enum.map(&:queue.len/1) |> Enum.sum()
    entry = {from, pid, ahead, Process.monitor(pid)}
    queue = Map.get(state.waiting, who, :queue.new())
    turn = if who in state.turn, do: state.turn, else: state.turn ++ [who]
    state = %{state | waiting: Map.put(state.waiting, who, :queue.in(entry, queue)), turn: turn}
    {:noreply, grant(state)}
  end

  def handle_call(:status, _from, state) do
    waiting = for who <- state.turn, do: {who, :queue.len(state.waiting[who])}

    {:reply,
     %{
       slots: slots(),
       running: Enum.map(state.running, fn {_pid, {who, _}} -> who end),
       waiting: waiting
     }, state}
  end

  @impl true
  def handle_cast({:done, pid}, state), do: {:noreply, state |> release(pid) |> grant()}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A caller that died while waiting is dropped; one that held a slot frees it.
    waiting =
      Map.new(state.waiting, fn {who, q} ->
        {who, :queue.filter(fn {_from, p, _, _} -> p != pid end, q)}
      end)

    {:noreply, %{state | waiting: waiting} |> prune() |> release(pid) |> grant()}
  end

  defp release(state, pid) do
    case Map.pop(state.running, pid) do
      {nil, _} ->
        state

      {{_who, ref}, running} ->
        Process.demonitor(ref, [:flush])
        %{state | running: running}
    end
  end

  # Free slots go to the people waiting, one each in turn.
  defp grant(state) do
    if map_size(state.running) < slots() and state.turn != [] do
      [who | rest] = state.turn
      {{:value, {from, pid, ahead, ref}}, queue} = :queue.out(state.waiting[who])
      GenServer.reply(from, {:ok, ahead})

      state = %{
        state
        | running: Map.put(state.running, pid, {who, ref}),
          waiting: Map.put(state.waiting, who, queue),
          turn: if(:queue.is_empty(queue), do: rest, else: rest ++ [who])
      }

      state |> prune() |> grant()
    else
      state
    end
  end

  defp prune(state) do
    empty = for {who, q} <- state.waiting, :queue.is_empty(q), do: who
    %{state | waiting: Map.drop(state.waiting, empty), turn: state.turn -- empty}
  end
end
