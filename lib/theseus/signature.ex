defmodule Theseus.Signature do
  @moduledoc """
  Identifies a kind of crash, so the same bug on different inputs is handled
  once: the unit, the function and arity, the exception type and the
  message with numbers, pids, references, quoted text and data structures
  stripped.
  """

  @enforce_keys [:id, :unit, :fun, :arity, :exception, :message]
  defstruct [:id, :unit, :fun, :arity, :exception, :message]

  @type t :: %__MODULE__{
          id: String.t(),
          unit: module(),
          fun: atom(),
          arity: non_neg_integer(),
          exception: atom(),
          message: String.t()
        }

  @doc "The signature of `error` raised by `unit.fun/arity`."
  @spec of(module(), atom(), non_neg_integer(), term()) :: t()
  def of(unit, fun, arity, error) do
    {exception, message} = describe(error)
    message = normalize(message)
    key = :erlang.term_to_binary({unit, fun, arity, exception, message})
    id = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    %__MODULE__{
      id: id,
      unit: unit,
      fun: fun,
      arity: arity,
      exception: exception,
      message: message
    }
  end

  @doc "Whether `error` from `unit.fun/arity` has this signature."
  @spec matches?(t() | nil, module(), atom(), non_neg_integer(), term()) :: boolean()
  def matches?(nil, _unit, _fun, _arity, _error), do: false

  def matches?(%__MODULE__{id: id}, unit, fun, arity, error),
    do: of(unit, fun, arity, error).id == id

  @doc "One line for people: `FunctionClauseError in Sample.Input.parse/1`."
  @spec describe_short(t()) :: String.t()
  def describe_short(%__MODULE__{} = s),
    do: "#{inspect(s.exception)} in #{inspect(s.unit)}.#{s.fun}/#{s.arity}"

  defp describe(%{__exception__: true, __struct__: type} = e) do
    message =
      try do
        Exception.message(e)
      rescue
        _ -> ""
      end

    {type, message}
  end

  defp describe({kind, reason}) when kind in [:throw, :exit],
    do: {kind, inspect(reason, limit: 5, printable_limit: 100)}

  defp describe(other), do: {:error, inspect(other, limit: 5, printable_limit: 100)}

  defp normalize(message) do
    message
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.replace(~r/Theseus\.Candidate\.[A-Za-z0-9]+\./, "")
    |> String.replace(~r/"(?:[^"\\]|\\.)*"/, ~s("_"))
    |> String.replace(~r/#(?:PID|Reference|Port|Function)<[^>]*>/, "#ref")
    |> String.replace(~r/%\{.*\}/, "%{}")
    |> String.replace(~r/\[.*\]/, "[]")
    |> String.replace(~r/\d+/, "N")
    |> String.slice(0, 200)
  end
end
