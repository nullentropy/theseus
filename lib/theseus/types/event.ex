defmodule Theseus.Event do
  @moduledoc """
  A ledger entry. `body` is the event itself, for example
  `{:promoted, unit, from_hash, to_hash}`.

  Bodies:

    * `{:version_recorded, %Theseus.Version{beam: nil}}`
    * `{:unit_registered, %Theseus.Unit{}}`
    * `{:change_proposed, %Theseus.Change{}}`
    * `{:validated, change_id, %Theseus.Report{}}`
    * `{:gate_decision, change_id, decision, by}`
    * `{:promoted, module, from_hash, to_hash, change_id}`
    * `{:rolled_back, module, from_hash, to_hash, reason}`
    * `{:rejected, change_id, reason}`

  `unit` is the unit an event is about. Events about a spec module carry the
  unit it specifies, so a unit's history includes its spec changes.
  `branch` is the branch the event belongs to (see `Theseus.Branches`).
  `by` is the email address of the person who acted, when one did and is
  known (see `Theseus.Team`); events from before it was recorded have no
  `by` key, so read it with `Map.get/2`.
  """

  @type actor :: :system | :human | :agent | :gate

  @type t :: %__MODULE__{
          seq: pos_integer(),
          id: String.t(),
          at: DateTime.t(),
          actor: actor(),
          unit: module() | nil,
          branch: String.t(),
          by: String.t() | nil,
          body: tuple()
        }

  @enforce_keys [:seq, :id, :at, :actor, :body]
  defstruct [:seq, :id, :at, :actor, :unit, :body, branch: "main", by: nil]
end
