defmodule Theseus.Approvals do
  @moduledoc """
  Who may approve and reject which changes, in team mode (`Theseus.Team`).
  In local mode whoever holds the reviewer link decides everything, as
  before.

  For the changes approved together (one change, or a group):

    1. On the live branch, a reviewer or an admin approves. On another
       branch, also the engineer who created it.
    2. On the live branch, someone other than the person who proposed any
       of them (`main_needs_another`, default true).
    3. A change to the spec of a unit with owners, a change to a schema
       unit with owners, or a merge touching a unit with owners needs one
       of that unit's owners (`owners`, default true).

  An admin may approve over rules 2 and 3 with a reason, as an admin may
  bypass a protected branch on GitHub; the ledger records the override.
  Rule 1 has no override. Config `:approvals`: `main_needs_another`,
  `owners`.

  Rejecting needs a reviewer or an admin, the person who proposed the
  change, or, on another branch, the engineer who created it.
  """

  alias Theseus.{Branches, Change, Team, Version}

  @doc """
  Whether `person` may approve `changes`: `:ok`, `{:override, reasons}` when
  only an admin's override with a reason would let them, or `{:error, why}`.
  """
  @spec check([Change.t()], map() | nil) :: :ok | {:override, [String.t()]} | {:error, String.t()}
  def check(changes, person) do
    cond do
      Team.mode() == :local ->
        :ok

      person == nil ->
        {:error, "sign in to approve"}

      not may_decide?(changes, person) ->
        {:error,
         "on the live branch a reviewer or an admin approves; you are #{article(person.role)}"}

      true ->
        case rules(changes, person) do
          [] -> :ok
          reasons -> {:override, reasons}
        end
    end
  end

  @doc "Whether `person` may reject `changes`."
  @spec may_reject?([Change.t()], map() | nil) :: boolean()
  def may_reject?(changes, person) do
    Team.mode() == :local or
      (person != nil and
         (may_decide?(changes, person) or
            Enum.any?(changes, &(&1.proposer[:person] == person.email))))
  end

  defp may_decide?([first | _], person) do
    person.role in ["reviewer", "admin"] or
      (first.branch != Branches.live() and Branches.creator(first.branch) == person.email)
  end

  defp rules([first | _] = changes, person) do
    live? = first.branch == Branches.live()

    proposed =
      if live? and setting(:main_needs_another) and
           Enum.any?(changes, &(&1.proposer[:person] == person.email)),
         do: ["you proposed it, and someone else approves changes to the live branch"],
         else: []

    owned =
      if setting(:owners) do
        for c <- changes,
            owners = Team.owners(c.unit),
            owners != [] and person.email not in owners and owner_rule?(c),
            do:
              "#{inspect(c.unit)} is owned by #{Enum.join(owners, ", ")}, and one of them approves #{what(c)}"
      else
        []
      end

    proposed ++ owned
  end

  defp owner_rule?(c) do
    c.trigger.kind == :merge or Change.spec_candidate(c) != nil or schema?(c)
  end

  defp what(c) do
    cond do
      c.trigger.kind == :merge -> "merges into it"
      Change.spec_candidate(c) != nil -> "changes to its spec"
      true -> "changes to its tables"
    end
  end

  defp schema?(c) do
    case Change.unit_candidate(c) do
      %Version{ast: ast} when ast != nil -> Theseus.Schema.schema_unit?(ast)
      _ -> false
    end
  end

  defp setting(key), do: Keyword.get(Application.get_env(:theseus, :approvals, []), key, true)

  defp article("admin"), do: "an admin"
  defp article("engineer"), do: "an engineer"
  defp article(role), do: "a #{role}"
end
