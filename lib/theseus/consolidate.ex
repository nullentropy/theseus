defmodule Theseus.Consolidate do
  @moduledoc """
  Keeps units legible for agents. When a unit has had more than `:after`
  promoted changes (default 10) since its last consolidation, and then no
  change for `:quiet_ms` (default 60 s) and none pending, the in-process
  proposer rewrites it cleanly with exactly the same behaviour
  (`Theseus.Proposer.consolidate/1`).

  The rewrite is a change like any other, with trigger `:consolidate` and
  `behaviour_change: false`, so replay and shadow must show no differences.
  The automatic gate promotes it only if replay and shadow both pass (see
  `Theseus.Gate.AutoBounded`); otherwise a person decides. A started
  consolidation is a ledger event; whether it succeeds or not, the count
  starts again from there.

  Config `:consolidate`: `:enabled` (default true), `:after`, `:quiet_ms`.
  It needs a model (`Theseus.LLM.available?/0`).
  """

  use GenServer
  require Logger

  alias Theseus.{Change, Changes, Ledger, LLM, Proposer, Registry}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # From `Theseus.Changes` after every promotion.
  def promoted(%Change{} = change), do: GenServer.cast(__MODULE__, {:promoted, change})

  @doc """
  Changes promoted to `unit` (the unit, its spec, or both) since its last
  consolidation started, not counting consolidations.
  """
  @spec changes_since(module()) :: non_neg_integer()
  def changes_since(unit) do
    live = Theseus.Branches.live()
    Ledger.memo({:changes_since, unit, live}, fn -> count_since(unit, live) end)
  end

  defp count_since(unit, live) do
    events = Ledger.events_for(unit) |> Enum.filter(&(&1.branch == live))

    marker =
      events
      |> Enum.filter(&match?(%{body: {:consolidation_started, ^unit, _, _}}, &1))
      |> List.last()

    after_seq = if marker, do: marker.seq, else: 0

    consolidations =
      for %{body: {:change_proposed, %Change{trigger: %{kind: :consolidate}, id: id}}} <- events,
          into: MapSet.new(),
          do: id

    events
    |> Enum.flat_map(fn
      %{seq: seq, body: {:promoted, _module, _from, _to, id}}
      when seq > after_seq and is_binary(id) ->
        if MapSet.member?(consolidations, id), do: [], else: [id]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> length()
  end

  @doc "How many changes a unit may have before it is consolidated."
  def threshold, do: setting(:after, 10)

  defp setting(key, default),
    do: Application.get_env(:theseus, :consolidate, []) |> Keyword.get(key, default)

  ## Server

  @impl true
  def init(_opts) do
    # Units already past the threshold get their quiet period now.
    state = %{timers: %{}, running: %{}}

    state =
      Enum.reduce(Registry.units(), state, fn unit, acc ->
        if setting(:enabled, true) and changes_since(unit.module) > threshold(),
          do: schedule(acc, unit.module),
          else: acc
      end)

    {:ok, state}
  end

  @impl true
  def handle_cast({:promoted, %Change{trigger: %{kind: :consolidate}}}, state),
    do: {:noreply, state}

  def handle_cast({:promoted, %Change{removes: removes}}, state) when removes != nil,
    do: {:noreply, state}

  def handle_cast({:promoted, %Change{unit: unit}}, state) do
    if setting(:enabled, true) and changes_since(unit) > threshold(),
      do: {:noreply, schedule(state, unit)},
      else: {:noreply, state}
  end

  @impl true
  def handle_info({:quiet, unit}, state) do
    state = %{state | timers: Map.delete(state.timers, unit)}

    cond do
      not setting(:enabled, true) or Map.has_key?(state.running, unit) ->
        {:noreply, state}

      pending?(unit) ->
        {:noreply, schedule(state, unit)}

      not LLM.available?() ->
        Logger.info("not consolidating #{inspect(unit)}: #{LLM.name()} is not available")
        {:noreply, state}

      true ->
        {:noreply, start(state, unit)}
    end
  end

  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {unit, running} = Map.pop(state.running, ref)
    finished(unit, result)
    {:noreply, %{state | running: running}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    {unit, running} = Map.pop(state.running, ref)
    finished(unit, {:error, {:proposer_crashed, reason}})
    {:noreply, %{state | running: running}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state, unit) do
    with timer when is_reference(timer) <- state.timers[unit], do: Process.cancel_timer(timer)
    timer = Process.send_after(self(), {:quiet, unit}, setting(:quiet_ms, 60_000))
    %{state | timers: Map.put(state.timers, unit, timer)}
  end

  defp pending?(unit) do
    Enum.any?(Changes.list(unit: unit, branch: Theseus.Branches.live(), limit: :all), fn {c, _} ->
      c.status in [:proposed, :shadowing, :held]
    end)
  end

  defp start(state, unit) do
    n = changes_since(unit)
    base = Registry.fetch!(unit).current_version
    {:ok, _} = Ledger.append({:consolidation_started, unit, base, n}, actor: :system, unit: unit)

    task =
      Task.Supervisor.async_nolink(Theseus.ProposerSupervisor, Proposer, :consolidate, [
        %{unit: unit, changes_since: n}
      ])

    %{state | running: Map.put(state.running, task.ref, unit)}
  end

  # A started consolidation counts whatever happens; only failures to
  # propose anything need their own event.
  defp finished(_unit, {:ok, %Change{}}), do: :ok

  defp finished(unit, {:error, reason}) do
    {:ok, _} =
      Ledger.append({:consolidation_failed, unit, Theseus.Describe.text(reason)},
        actor: :system,
        unit: unit
      )
  end
end
