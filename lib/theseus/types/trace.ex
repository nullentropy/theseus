defmodule Theseus.Trace do
  @moduledoc """
  One recorded invocation of a unit through `Theseus.call/3`.
  """

  @type result ::
          {:ok, term()}
          | {:error, Exception.t() | {:throw | :exit, term()}, Exception.stacktrace()}

  @type t :: %__MODULE__{
          id: pos_integer(),
          unit: module(),
          fun: atom(),
          args: [term()],
          result: result(),
          state_before: term(),
          state_after: term(),
          version: String.t() | nil,
          at: DateTime.t(),
          tags: [atom()]
        }

  @enforce_keys [:id, :unit, :fun, :args, :result, :at]
  defstruct [
    :id,
    :unit,
    :fun,
    :args,
    :result,
    :state_before,
    :state_after,
    :version,
    :at,
    tags: []
  ]
end
