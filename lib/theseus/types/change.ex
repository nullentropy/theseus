defmodule Theseus.Change do
  @moduledoc """
  A proposed change to one unit on one branch: a new version of the unit,
  of its spec, or both. A change with no base version creates the unit. A
  change with `removes` set removes the unit and its spec: it has no
  candidates, and `removes` holds the versions it takes away, `%{unit:
  hash, spec: hash | nil}`.

  Changes proposed together share a `group` id. They are validated in one
  candidate world, approved and rejected together, and loaded together.
  """

  alias Theseus.Version

  @type status :: :proposed | :shadowing | :held | :promoted | :rejected

  @type t :: %__MODULE__{
          id: String.t(),
          trigger: %{
            kind: :human | :crash | :consolidate | :merge,
            payload: term(),
            untrusted: boolean()
          },
          proposer: %{kind: :mcp | :in_process | :iex, client: String.t() | nil},
          intent: String.t(),
          unit: module(),
          candidates: [Version.t()],
          behaviour_change: boolean(),
          rationale: String.t(),
          status: status(),
          branch: String.t(),
          group: String.t() | nil,
          removes: %{unit: String.t(), spec: String.t() | nil} | nil,
          at: DateTime.t()
        }

  @enforce_keys [:id, :trigger, :proposer, :intent, :unit, :candidates]
  defstruct [
    :id,
    :trigger,
    :proposer,
    :intent,
    :unit,
    :candidates,
    :at,
    behaviour_change: true,
    rationale: "",
    status: :proposed,
    branch: "main",
    group: nil,
    removes: nil
  ]

  @doc "A new change id."
  def new_id,
    do: "chg_" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)

  @doc "A new group id."
  def new_group_id,
    do: "grp_" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)

  @doc "Whether the change removes its unit."
  def removes?(%__MODULE__{} = change), do: Map.get(change, :removes) != nil

  @doc "Whether the change creates its unit."
  def creates?(%__MODULE__{candidates: candidates, unit: unit}) do
    Enum.any?(candidates, &(&1.unit == unit and &1.parent == nil))
  end

  @doc "The candidate for the unit itself, if any."
  def unit_candidate(%__MODULE__{candidates: candidates, unit: unit}),
    do: Enum.find(candidates, &(&1.unit == unit))

  @doc "Whether compaction removed the change's code (see `Theseus.Compact`)."
  def compacted?(%__MODULE__{candidates: candidates}),
    do: Enum.any?(candidates, &Version.compacted?/1)

  @doc "The candidate for the unit's spec, if any."
  def spec_candidate(%__MODULE__{candidates: candidates, unit: unit}),
    do: Enum.find(candidates, &(&1.unit == Theseus.Unit.spec_module(unit)))
end
