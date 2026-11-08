defmodule Theseus.Ticker do
  @moduledoc """
  Scheduled work for the application. Units never read the clock, so the
  engine tells the app what time it is: every `tick_seconds` (default 60)
  it calls the root endpoint unit's optional `tick/1` with
  `%{now: DateTime, last: DateTime | nil}`, where `last` is the previous
  tick's time (nil for the first one after a start). The call goes through
  `Theseus.call/3`, so ticks are recorded, replayed and repaired like any
  call. The app does what is due between `last` and `now`.

  Config: `config :theseus, :app, tick_seconds: 60`; 0 turns ticks off.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Ticks now (for tests and iex). Returns what `tick/1` returned, or nil."
  @spec tick() :: term()
  def tick, do: GenServer.call(__MODULE__, :tick, 30_000)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{last: nil}}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {result, state} = run(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule()
    {_result, state} = run(state)
    {:noreply, state}
  end

  defp run(state) do
    now = DateTime.utc_now()

    result =
      with unit when unit != nil <- Theseus.Web.endpoint(),
           true <- function_exported?(unit, :tick, 1) do
        try do
          tick = %{now: now, last: state.last, id: Theseus.Store.id(%{tick: now})}

          Theseus.Effects.run("#{inspect(unit)}.tick", fn ->
            Theseus.call(unit, :tick, [tick])
          end)
        rescue
          e ->
            Logger.warning("the app's tick/1 failed: #{Exception.message(e)}")
            nil
        catch
          kind, reason ->
            Logger.warning("the app's tick/1 failed: #{kind} #{inspect(reason, limit: 5)}")
            nil
        end
      else
        _ -> nil
      end

    {result, %{state | last: now}}
  end

  defp schedule do
    case Keyword.get(Application.get_env(:theseus, :app, []), :tick_seconds, 60) do
      seconds when is_integer(seconds) and seconds > 0 ->
        Process.send_after(self(), :tick, seconds * 1000)

      _ ->
        :ok
    end
  end
end
