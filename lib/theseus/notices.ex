defmodule Theseus.Notices do
  @moduledoc """
  Notices the engine sends people in team mode (step 5 of
  `docs/team-design.md`), through the outbox (`Theseus.Outbox`), as the
  app's messages go: held on the Outbox page, or sent by its webhook.

    * A change waits for you: to the people who may approve it, other than
      its proposer (reviewers and admins on the live branch, the unit's
      owners when their rule applies, the branch's owner elsewhere). A
      group sends one notice, once all of it waits.
    * Your change was combined with one approved before it, or could not
      be (`Theseus.Combine`): to its proposer.
    * A unit your branch changed was changed on its parent: to the
      branch's owner.
    * A crash on the live branch started a repair: to the admins.

  Config `:notices, enabled:` (default true). Local mode sends none: there
  are no people to send them to.
  """

  alias Theseus.{Approvals, Branches, Change, Changes, Outbox, ReviewSignIn, Team}

  @doc "Whether notices are sent."
  def enabled?,
    do:
      Team.mode() == :team and
        Keyword.get(Application.get_env(:theseus, :notices, []), :enabled, true)

  @doc false
  # From Theseus.Changes, whenever a change's status changes.
  def changed(%Change{status: :held} = change) do
    if enabled?(), do: held(change)
    :ok
  end

  def changed(%Change{status: :promoted} = change) do
    if enabled?(), do: parent_moved(change)
    :ok
  end

  def changed(_change), do: :ok

  defp held(%Change{group: nil} = change), do: waiting([change], "/changes/#{change.id}")

  defp held(%Change{group: group}) do
    members = for {c, _} <- Changes.group(group), do: c
    if Enum.all?(members, &(&1.status == :held)), do: waiting(members, "/groups/#{group}")
  end

  defp waiting([first | _] = changes, path) do
    proposers = changes |> Enum.map(& &1.proposer[:person]) |> Enum.reject(&is_nil/1)
    units = changes |> Enum.map(&inspect(&1.unit)) |> Enum.join(", ")

    send_notice(
      deciders(changes, proposers),
      "Waiting for you: #{first.intent}",
      "#{who(first)} proposed a change to #{units} on #{first.branch}, and it passed its checks.\n\n" <>
        "#{first.intent}\n\nReview it: #{ReviewSignIn.url()}#{path}"
    )
  end

  # On the live branch, the people who may approve it as it is, or the
  # admins when only an override would; elsewhere the branch's owner.
  defp deciders([first | _] = changes, proposers) do
    if first.branch == Branches.live() do
      people = Enum.reject(Team.people(), &(&1.email in proposers))

      case for(p <- people, Approvals.check(changes, p) == :ok, do: p.email) do
        [] -> for p <- people, p.role == "admin", do: p.email
        ok -> ok
      end
    else
      owner = Branches.creator(first.branch)
      if owner != nil and owner not in proposers, do: [owner], else: []
    end
  end

  @doc false
  # From Theseus.Combine: a stale change was combined into `new`, or could
  # not be combined because both changed `what`.
  def combined(%Change{} = old, new_id, onto_id) do
    if enabled?() do
      send_notice(
        List.wrap(old.proposer[:person]),
        "Your change was combined: #{old.intent}",
        "#{onto_id} changed #{inspect(old.unit)} first, in other functions, so the engine combined your #{old.id} with it as #{new_id}, which waits for approval.\n\n" <>
          "#{ReviewSignIn.url()}/changes/#{new_id}"
      )
    end

    :ok
  end

  def not_combined(%Change{} = old, what, onto_id) do
    if enabled?() do
      send_notice(
        List.wrap(old.proposer[:person]),
        "Your change needs proposing again: #{old.intent}",
        "#{onto_id} was approved first and changed the same parts of #{inspect(old.unit)} (#{Enum.join(what, ", ")}), so #{old.id} was rejected. Propose it again on top of the current version.\n\n" <>
          "#{ReviewSignIn.url()}/changes/#{old.id}"
      )
    end

    :ok
  end

  # Open branches forked from this change's branch that changed its unit
  # too: their owners hear that the parent moved.
  defp parent_moved(%Change{} = change) do
    for b <- Branches.list(),
        b.from == change.branch,
        not b.closed,
        is_binary(b.owner),
        b.owner != change.proposer[:person],
        %{unit: unit, status: :conflict} <- Branches.diff(b.name, b.from),
        unit == change.unit do
      send_notice(
        [b.owner],
        "#{change.branch} changed #{inspect(unit)}, which your branch #{b.name} changes too",
        "#{change.id} was approved on #{change.branch}: #{change.intent}\n\n" <>
          "Your branch #{b.name} changed #{inspect(unit)} too. Bring #{change.branch}'s changes in (propose_merge from #{change.branch} into #{b.name}) before merging back; edits to different functions are combined.\n\n" <>
          "#{ReviewSignIn.url()}/branches/#{b.name}"
      )
    end

    :ok
  end

  @doc false
  # From Theseus.Trigger, when a crash starts its first repair.
  def repair_started(what) do
    if enabled?() do
      admins = for p <- Team.people(), p.role == "admin", do: p.email

      send_notice(
        admins,
        "A crash started a repair",
        "#{what}\n\nThe engine is proposing a fix. #{ReviewSignIn.url()}/"
      )
    end

    :ok
  end

  defp who(%Change{proposer: p}), do: p[:person] || p[:client] || "the engine"

  defp send_notice([], _subject, _text), do: :ok

  defp send_notice(to, subject, text) do
    subject = subject |> String.replace(~r/[[:cntrl:]]/, " ") |> String.slice(0, 200)
    Outbox.send_messages([%{to: Enum.uniq(to), subject: subject, text: text}], "theseus")
    :ok
  end
end
