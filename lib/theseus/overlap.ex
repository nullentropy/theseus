defmodule Theseus.Overlap do
  @moduledoc """
  Who else is changing a unit, so an agent can coordinate or pick another
  unit before writing anything (step 4 of `docs/team-design.md`). It is
  information, not a lock. For a unit on a branch:

    * changes to it waiting on the same branch, and who proposed them;
    * other open branches that changed it and have not merged it yet, with
      their owners, and changes to it waiting there;
    * on a branch, changes to it on the parent since the branch was made.

  list_units and get_unit show these notes.
  """

  alias Theseus.{Branches, Changes}

  @doc "Notes for every unit with any, on `branch`: `%{unit => [note]}`."
  @spec notes(String.t()) :: %{module() => [String.t()]}
  def notes(branch) do
    waiting =
      for {c, _} <- Changes.list(limit: :all),
          c.status in [:held, :shadowing],
          do: c

    here =
      for c <- waiting, c.branch == branch do
        {c.unit, "#{c.id} is waiting, proposed by #{who(c)}: #{short(c.intent)}"}
      end

    elsewhere =
      for b <- Branches.list(),
          b.name != branch,
          not b.closed,
          b.from != nil,
          %{unit: unit, status: status} <- Branches.diff(b.name, b.from),
          status in [:from, :conflict] do
        {unit, "changed on branch #{b.name}#{owner(b)}, not merged yet"}
      end

    waiting_elsewhere =
      for c <- waiting, c.branch != branch, not Branches.closed?(c.branch) do
        {c.unit, "#{c.id} is waiting on branch #{c.branch}, proposed by #{who(c)}"}
      end

    moved =
      case Branches.parent(branch) do
        nil ->
          []

        parent ->
          for %{unit: unit, status: status} <- Branches.diff(branch, parent),
              status in [:into, :conflict] do
            {unit,
             "changed on #{parent} since this branch was made; propose_merge from #{parent} brings it in"}
          end
      end

    (here ++ elsewhere ++ waiting_elsewhere ++ moved)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {unit, notes} -> {unit, Enum.uniq(notes)} end)
  end

  @doc "The notes for one unit on `branch`."
  @spec for_unit(module(), String.t()) :: [String.t()]
  def for_unit(unit, branch), do: Map.get(notes(branch), unit, [])

  defp who(c), do: c.proposer[:person] || c.proposer[:client] || to_string(c.proposer[:kind])

  defp owner(%{owner: nil}), do: ""
  defp owner(%{owner: owner}), do: " (#{owner})"

  defp short(text) do
    text = String.replace(text, ~r/\s+/, " ")
    if String.length(text) > 80, do: String.slice(text, 0, 77) <> "...", else: text
  end
end
