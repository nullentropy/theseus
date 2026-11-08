defmodule Theseus do
  @moduledoc """
  The iex interface.

      Theseus.status()
      Theseus.pending()
      Theseus.show("chg_...")
      Theseus.approve("chg_...")
      Theseus.reject("chg_...", "reason")
      Theseus.history(Sample.Pricing)
      Theseus.rollback(Sample.Pricing)
      Theseus.undo_group("grp_...")
      Theseus.rebuild()
      Theseus.crashes()
      Theseus.retry_crash("signature id")
      Theseus.llm_log()
      Theseus.branches()
      Theseus.fork("cheaper-shipping")
      Theseus.preview("cheaper-shipping")
      Theseus.merge("cheaper-shipping", "main")
      Theseus.switch("cheaper-shipping")
      Theseus.group("grp_...")
      Theseus.connections()
      Theseus.services()
      Theseus.saved_state()
  """

  alias Theseus.{Changes, Describe, Event, Introspect, Loader, Registry, Traces, Version}

  @doc "Invokes a unit and records a trace. See `Theseus.Call`."
  defdelegate call(unit, fun, args), to: Theseus.Call

  @doc "One line per unit."
  def status do
    for unit <- Introspect.units() do
      spec = Registry.fetch(unit.spec)

      %{
        unit: unit.module,
        kind: unit.kind,
        version: Version.short(unit.current_version),
        spec_version:
          with({:ok, s} <- spec, do: Version.short(s.current_version), else: (_ -> nil)),
        versions: length(Theseus.Ledger.version_hashes(unit.module)),
        traces: Traces.count(unit.module),
        pending: length(Changes.list(status: :held, unit: unit.module)),
        since_rewrite: Theseus.Consolidate.changes_since(unit.module),
        last_change: with(%Event{at: at} <- List.last(Introspect.history(unit.module, 1)), do: at)
      }
    end
  end

  @doc "Changes waiting for a person."
  def pending do
    for {change, _report} <- Changes.list(status: :held), do: Describe.summary(change)
  end

  @doc "A change as a person reviews it: intent, evidence, spec changes. No code."
  def show(id) do
    case Changes.get(id) do
      {:ok, change, report} -> Describe.change(change, report)
      :error -> {:error, :not_found}
    end
  end

  @doc "Approves a held change; for a change in a group, the whole group."
  def approve(id), do: Changes.approve(id, actor: :human)

  @doc "Rejects a change; for a change in a group, the whole group."
  def reject(id, reason), do: Changes.reject(id, reason, actor: :human)

  @doc "The changes proposed together in a group."
  def group(id), do: for({change, _report} <- Changes.group(id), do: Describe.summary(change))

  @doc "Connections to outside services, without secrets."
  def connections, do: Theseus.Connections.list()

  @doc "The outside services the app declares (see `Theseus.Services`)."
  def services, do: Theseus.Services.all()

  @doc "What is saved of each server unit's state: version, size and time."
  def saved_state, do: Theseus.State.saved()

  @doc "Rolls a unit or spec back to its previous version, or to a hash or hash prefix."
  def rollback(module, to \\ :previous), do: Loader.rollback(module, to, actor: :human)

  @doc "Undoes an approved group of changes (see `Theseus.Changes.undo_group/2`)."
  def undo_group(group), do: Theseus.Changes.undo_group(group, actor: :human)

  @doc """
  Compacts the running ledger now and prints what went (see
  `Theseus.Compact`). Options: `keep:`, `days:`, `dry_run: true`.
  """
  def compact(opts \\ []) do
    case Theseus.Compact.run(Theseus.Ledger.path(), opts) do
      {:ok, stats} -> IO.puts(Theseus.Compact.report(stats))
      {:error, why} -> IO.puts(why)
    end
  end

  @doc "Reconstructs every unit and spec from the ledger and checks the hashes."
  defdelegate rebuild(), to: Loader

  @doc "Every kind of crash seen, with its repair status."
  def crashes do
    for c <- Theseus.Trigger.list() do
      %{
        signature: c.id,
        crash: Theseus.Signature.describe_short(c.signature),
        status: c.status,
        seen: c.count,
        attempts: c.attempts,
        change: c.change_id,
        note: c.note
      }
    end
  end

  @doc "Allows new repair attempts for a crash marked as needing a person."
  def retry_crash(signature_id), do: Theseus.Trigger.retry(signature_id, :human)

  @doc "The last LLM exchanges of the crash repairer, newest first, redacted."
  defdelegate llm_log(), to: Theseus.LLM.Log, as: :list

  @doc "Every branch, which one is live, and how each differs from its parent."
  def branches do
    for b <- Theseus.Branches.list() do
      differs =
        if b.from,
          do:
            for(
              %{status: s, unit: u} <- Theseus.Branches.diff(b.name, b.from),
              s != :same,
              do: {u, s}
            ),
          else: []

      open =
        Theseus.Changes.list(branch: b.name, limit: :all)
        |> Enum.count(fn {c, _} -> c.status in [:held, :shadowing] end)

      b |> Map.put(:differs_from_parent, differs) |> Map.put(:open_changes, open)
    end
  end

  @doc "Forks a branch from `from` (default main). Nothing live changes."
  def fork(name, from \\ "main"), do: Theseus.Branches.create(name, from, actor: :human)

  @doc "Makes `branch` the live branch: loads its versions into the running system."
  def switch(branch), do: Loader.switch(branch, actor: :human)

  @doc "Proposes merging `from` into `into`. The merge changes are held for approval."
  def merge(from, into \\ "main"),
    do: Theseus.Branches.merge(from, into, proposer: %{kind: :iex, client: nil})

  @doc "Runs a branch on its own node and port. Returns its URL."
  defdelegate preview(branch, opts \\ []), to: Theseus.Previews, as: :start

  defdelegate stop_preview(branch), to: Theseus.Previews, as: :stop

  @doc "A unit's ledger entries (including its spec's), oldest first."
  def history(unit, limit \\ 50) do
    for %Event{} = e <- Introspect.history(unit, limit) do
      %{seq: e.seq, at: e.at, actor: e.actor, branch: e.branch, event: Describe.event(e.body)}
    end
  end
end
