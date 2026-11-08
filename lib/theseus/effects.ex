defmodule Theseus.Effects do
  @moduledoc """
  Runs the app's callbacks the way the engine runs every one of them: in
  one store transaction (`Theseus.Store.run/3`), then it queues the
  messages the result sends (`Theseus.Outbox`) and the requests it makes
  (`Theseus.Fetch`), and returns what is left of the result.
  """

  @doc "Runs `fun` for `source` and carries out its effects. Returns the rest of its result."
  @spec run(String.t(), (-> term()), term()) :: term()
  def run(source, fun, conflict \\ :conflict) do
    source
    |> Theseus.Store.run(fun, conflict)
    |> Theseus.Outbox.take(source)
    |> Theseus.Fetch.take(source)
  end

  @doc """
  Calls the root endpoint unit's optional callback `name` with `arg`.
  Returns `{:ok, result}`, `:none` when the app has no such callback, or
  `{:error, why}` when it failed.
  """
  @spec callback(atom(), term()) :: {:ok, term()} | :none | {:error, String.t()}
  def callback(name, arg) do
    with unit when unit != nil <- Theseus.Web.endpoint(),
         true <- function_exported?(unit, name, 1) do
      source = "#{inspect(unit)}.#{name}"

      try do
        {:ok, run(source, fn -> Theseus.call(unit, name, [arg]) end)}
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, reason -> {:error, "#{kind} #{inspect(reason, limit: 5)}"}
      end
    else
      _ -> :none
    end
  end

  @doc "A random id for a callback's argument; new rows take their ids from it (`Theseus.Store.id/2`)."
  @spec new_id() :: String.t()
  def new_id, do: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
end
