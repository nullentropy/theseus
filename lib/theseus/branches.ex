defmodule Theseus.Branches do
  @moduledoc """
  A branch is a named map from module to version, kept in the ledger.
  `main` exists from the start. Every event carries its branch.

    * `{:branch_created, name, from, units}`: a fork. `units` is the parent's
      units at that moment, so the branch starts from them.
    * `{:branch_switched, name, previous}`: the live system now runs `name`.
    * `{:branch_described, name, text}`: what the branch is for.
    * `{:branch_closed, name}`, `{:branch_reopened, name}`: a closed branch
      keeps its history, takes no changes and runs no preview.

  A branch's owner is the person who created it (the event's `by`).

  The running system loads exactly one branch, the live one. Changes to
  other branches are validated and recorded, never loaded; a branch can run
  as a preview on its own node and port (`Theseus.Previews`).

  Merges are between a branch and the branch it was forked from, in either
  direction. Each side's base version of a module is its version at the
  fork, or at the last merge change between the two that touched it (a
  merge change records the source versions it brought over). A module
  changed since its base on one side only is merged by a change on the
  target; changed on both sides, it is a conflict, resolved by a reconciled
  change proposed with `merge_from`.
  """

  alias Theseus.{Change, Changes, Event, Ledger, Unit, Version}

  @main "main"
  @name ~r/^[a-z0-9][a-z0-9_-]{0,39}$/

  def main, do: @main

  @doc "The branch the running system loads."
  @spec live() :: String.t()
  def live do
    Application.get_env(:theseus, :branch) ||
      :persistent_term.get({__MODULE__, :live}, nil) ||
      refresh_live()
  end

  @doc false
  # Reads the live branch from the ledger (the last switch, or main).
  def refresh_live do
    live =
      Ledger.events()
      |> Enum.reduce(@main, fn
        %Event{body: {:branch_switched, name, _}}, _ -> name
        _, acc -> acc
      end)

    :persistent_term.put({__MODULE__, :live}, live)
    live
  end

  @doc false
  def set_live(name), do: :persistent_term.put({__MODULE__, :live}, name)

  @doc """
  Every branch, main first: name, parent, when it was created, whether it
  is live, its owner, what it is for, and whether it is closed.
  """
  @spec list() :: [map()]
  def list do
    live = live()
    meta = meta()

    created =
      for {name, %Event{body: {:branch_created, _, from, _}, at: at} = e} <- forks() do
        Map.merge(
          %{name: name, from: from, created_at: at, live: name == live, owner: Map.get(e, :by)},
          Map.get(meta, name, %{description: nil, closed: false})
        )
      end

    [
      Map.merge(
        %{name: @main, from: nil, created_at: nil, live: live == @main, owner: nil},
        Map.get(meta, @main, %{description: nil, closed: false})
      )
      | created
    ]
  end

  # Each branch's description and whether it is closed.
  defp meta do
    Ledger.memo(:branch_meta, fn ->
      Enum.reduce(Ledger.events(), %{}, fn
        %Event{body: {:branch_described, name, text}}, acc ->
          Map.update(acc, name, %{description: text, closed: false}, &%{&1 | description: text})

        %Event{body: {:branch_closed, name}}, acc ->
          Map.update(acc, name, %{description: nil, closed: true}, &%{&1 | closed: true})

        %Event{body: {:branch_reopened, name}}, acc ->
          Map.update(acc, name, %{description: nil, closed: false}, &%{&1 | closed: false})

        _, acc ->
          acc
      end)
    end)
  end

  @doc "What a branch is for, or nil."
  @spec description(String.t()) :: String.t() | nil
  def description(name), do: get_in(meta(), [name, :description])

  @doc "Whether a branch is closed."
  @spec closed?(String.t()) :: boolean()
  def closed?(name), do: get_in(meta(), [name, :closed]) == true

  # Each fork's branch_created event, oldest first, by branch name.
  defp forks do
    Ledger.memo(:branch_forks, fn ->
      for %Event{body: {:branch_created, name, _, _}} = e <- Ledger.events(), do: {name, e}
    end)
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(@main), do: true
  def exists?(name) when is_binary(name), do: List.keymember?(forks(), name, 0)
  def exists?(_), do: false

  @doc "The branch a branch was forked from, or nil for main."
  def parent(name) do
    case List.keyfind(forks(), name, 0) do
      {_, %Event{body: {:branch_created, _, from, _}}} -> from
      nil -> nil
    end
  end

  @doc "Every unit and spec on a branch, with its current version there."
  @spec units(String.t()) :: [Unit.t()]
  def units(branch \\ live()),
    do: Ledger.memo({:branch_units, branch}, fn -> units_in(Ledger.events(), branch) end)

  @doc false
  # The fold behind units/1, over any events: compaction checks a compacted
  # ledger with it.
  def units_in(events, branch) do
    {start, after_seq} =
      case created(branch, events) do
        %Event{body: {:branch_created, _, _, units}, seq: seq} ->
          {Map.new(units, &{&1.module, &1}), seq}

        nil ->
          {%{}, 0}
      end

    events
    |> Enum.filter(&(&1.seq > after_seq and &1.branch == branch))
    |> Enum.reduce(start, fn
      %Event{body: {:unit_registered, %Unit{} = unit}}, acc ->
        Map.put(acc, unit.module, unit)

      %Event{body: {:promoted, module, _from, to, _}}, acc ->
        set_version(acc, module, to)

      %Event{body: {:rolled_back, module, _from, to, _}}, acc ->
        set_version(acc, module, to)

      %Event{body: {:unit_unregistered, module, _reason}}, acc ->
        Map.delete(acc, module)

      _event, acc ->
        acc
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.module)
  end

  defp set_version(units, module, hash) do
    case units do
      %{^module => unit} -> Map.put(units, module, %{unit | current_version: hash})
      _ -> units
    end
  end

  @doc "A unit or spec on a branch, or nil."
  @spec unit(String.t(), module()) :: Unit.t() | nil
  def unit(branch, module), do: Enum.find(units(branch), &(&1.module == module))

  @doc "A module's current version on a branch, or nil."
  @spec current(String.t(), module()) :: String.t() | nil
  def current(branch, module), do: with(%Unit{current_version: h} <- unit(branch, module), do: h)

  @doc """
  The base versions of a child branch and its parent, per module:
  `%{module => {child_version, parent_version}}`. They start as the fork
  snapshot and move with every merge change between the two.
  """
  @spec bases(String.t(), String.t()) :: %{module() => {String.t() | nil, String.t() | nil}}
  def bases(child, parent),
    do:
      Ledger.memo({:branch_bases, child, parent}, fn ->
        bases_in(Ledger.events(), child, parent)
      end)

  @doc false
  def bases_in(events, child, parent) do
    %Event{body: {:branch_created, ^child, ^parent, units}, seq: fork} = created(child, events)
    merges = merge_payloads(events)
    start = Map.new(units, &{&1.module, {&1.current_version, &1.current_version}})

    Enum.reduce(events, start, fn
      %Event{seq: seq, branch: branch, body: {:promoted, module, _from, to, id}}, acc
      when seq > fork and is_map_key(merges, id) ->
        %{from: source_branch, sources: sources} = merges[id]

        case {branch, source_branch, sources[module]} do
          {^parent, ^child, source} when source != nil -> Map.put(acc, module, {source, to})
          {^child, ^parent, source} when source != nil -> Map.put(acc, module, {to, source})
          _ -> acc
        end

      _event, acc ->
        acc
    end)
  end

  defp merge_payloads(events) do
    for %Event{body: {:change_proposed, %Change{trigger: %{kind: :merge, payload: p}, id: id}}} <-
          events,
        into: %{},
        do: {id, p}
  end

  defp created(@main, _events), do: nil

  defp created(name, events),
    do: Enum.find(events, &match?(%Event{body: {:branch_created, ^name, _, _}}, &1))

  ## Actions

  @doc """
  Forks `from` as a new branch. Branch names are lowercase letters, digits,
  `-` and `_`. Forking changes nothing that is live. Options: `:actor`,
  `:by` (the owner) and `:description`.
  """
  @spec create(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def create(name, from \\ @main, opts \\ []) do
    cond do
      not is_binary(name) or not Regex.match?(@name, name) ->
        {:error, "a branch name is lowercase letters, digits, - and _, up to 40 characters"}

      exists?(name) ->
        {:error, "branch #{name} already exists"}

      not exists?(from) ->
        {:error, "no branch named #{from}"}

      String.length(String.trim(opts[:description] || "")) > 200 ->
        {:error, "a description is at most 200 characters"}

      true ->
        {:ok, _} =
          Ledger.append({:branch_created, name, from, units(from)},
            actor: Keyword.get(opts, :actor, :human),
            branch: name,
            by: Keyword.get(opts, :by)
          )

        case String.trim(opts[:description] || "") do
          "" -> :ok
          text -> describe(name, text, opts)
        end
    end
  end

  @doc "Says what a branch is for, in up to 200 characters."
  @spec describe(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def describe(name, text, opts \\ []) do
    text = String.trim(text || "")

    cond do
      not exists?(name) -> {:error, "no branch named #{name}"}
      String.length(text) > 200 -> {:error, "a description is at most 200 characters"}
      true -> append({:branch_described, name, text}, name, opts)
    end
  end

  @doc """
  Closes a branch: it keeps its history, takes no more changes and stops
  its preview. Main and the live branch stay open.
  """
  @spec close(String.t(), keyword()) :: :ok | {:error, String.t()}
  def close(name, opts \\ []) do
    cond do
      not exists?(name) -> {:error, "no branch named #{name}"}
      name == @main -> {:error, "main stays open"}
      name == live() -> {:error, "the live branch stays open"}
      closed?(name) -> {:error, "branch #{name} is already closed"}
      true -> with :ok <- append({:branch_closed, name}, name, opts), do: stop_preview(name)
    end
  end

  @doc "Opens a closed branch again."
  @spec reopen(String.t(), keyword()) :: :ok | {:error, String.t()}
  def reopen(name, opts \\ []) do
    if closed?(name),
      do: append({:branch_reopened, name}, name, opts),
      else: {:error, "branch #{name} is not closed"}
  end

  defp stop_preview(name) do
    if Process.whereis(Theseus.Previews), do: Theseus.Previews.stop(name), else: :ok
  end

  defp append(body, name, opts) do
    {:ok, _} =
      Ledger.append(body,
        actor: Keyword.get(opts, :actor, :human),
        branch: name,
        by: Keyword.get(opts, :by)
      )

    :ok
  end

  @doc "The email address of the person who created a branch, or nil."
  @spec creator(String.t()) :: String.t() | nil
  def creator(name) do
    Ledger.memo({:branch_creator, name}, fn ->
      Enum.find_value(Ledger.events(), fn
        %Event{body: {:branch_created, ^name, _, _}} = e -> Map.get(e, :by)
        _ -> nil
      end)
    end)
  end

  @doc """
  How `from` and `into` differ, per unit: `:same` (nothing to merge),
  `:from` (only `from` changed: mergeable), `:into` (only `into` changed),
  or `:conflict`. Each entry lists the modules (unit and spec) involved.
  The two must be a branch and the branch it was forked from.
  """
  @spec diff(String.t(), String.t()) :: [map()] | {:error, String.t()}
  def diff(from, into) do
    cond do
      parent(from) == into ->
        do_diff(from, into, bases(from, into))

      parent(into) == from ->
        do_diff(from, into, flip(bases(into, from)))

      true ->
        {:error, "#{from} and #{into} can only be merged with the branch they were forked from"}
    end
  end

  defp flip(bases), do: Map.new(bases, fn {m, {child, parent}} -> {m, {parent, child}} end)

  # `bases` maps module => {from_base, into_base}.
  defp do_diff(from, into, bases) do
    from_units = Map.new(units(from), &{&1.module, &1})
    into_units = Map.new(units(into), &{&1.module, &1})

    modules =
      (Map.keys(from_units) ++ Map.keys(into_units))
      |> Enum.uniq()
      |> Enum.map(&if(Unit.spec_name?(&1), do: Unit.specified_unit(&1), else: &1))
      |> Enum.uniq()
      |> Enum.sort()

    for unit <- modules do
      parts =
        for module <- [unit, Unit.spec_module(unit)],
            Map.has_key?(from_units, module) or Map.has_key?(into_units, module) do
          f = from_units[module] && from_units[module].current_version
          i = into_units[module] && into_units[module].current_version
          {base_f, base_i} = Map.get(bases, module, {nil, nil})

          side =
            case {f == i, f != base_f, i != base_i} do
              {true, _, _} -> :same
              {false, true, false} -> :from
              {false, false, true} -> :into
              {false, true, true} -> :conflict
              {false, false, false} -> :same
            end

          %{module: module, from: f, into: i, side: side}
        end

      sides = Enum.map(parts, & &1.side) |> Enum.reject(&(&1 == :same)) |> Enum.uniq()

      status =
        case sides do
          [] -> :same
          [one] -> one
          _ -> :conflict
        end

      %{unit: unit, status: status, modules: parts}
    end
  end

  @doc """
  Proposes merging `from` into `into`: one change on `into` per unit that
  only `from` has changed, each validated and held for a person like any
  other change. Units changed on both sides are returned as conflicts; a
  reconciled version is proposed with `merge_from` (see
  `Theseus.Changes.propose/1`).

  Options: `:proposer` (default iex), `:actor`.
  """
  @spec merge(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def merge(from, into, opts \\ []) do
    cond do
      not exists?(from) ->
        {:error, "no branch named #{from}"}

      not exists?(into) ->
        {:error, "no branch named #{into}"}

      from == into ->
        {:error, "a branch cannot be merged into itself"}

      true ->
        with diff when is_list(diff) <- diff(from, into),
             do: {:ok, do_merge(from, into, diff, opts)}
    end
  end

  defp do_merge(from, into, diff, opts) do
    merge_id = "mrg_" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)

    proposals =
      for %{status: :from, unit: unit, modules: parts} <- diff do
        sources = for %{side: :from, module: m, from: h} <- parts, into: %{}, do: {m, h}
        merge_proposal(unit, sources, from, into, merge_id, opts)
      end

    # A unit changed on both sides is combined by function when the two
    # changed different parts (Theseus.Combine); otherwise it is a conflict.
    bases = merge_bases(from, into)

    {combined, conflicts} =
      for %{status: :conflict} = d <- diff, reduce: {[], []} do
        {combined, conflicts} ->
          case combine_parts(d.modules, bases) do
            {:ok, sources, texts} ->
              {combined ++ [{d.unit, sources, texts}], conflicts}

            {:conflict, _what} ->
              {combined, conflicts ++ [d.unit]}
          end
      end

    proposals =
      proposals ++
        for {unit, sources, texts} <- combined,
            do: merge_proposal(unit, sources, from, into, merge_id, opts, texts)

    # Several units merge as one group, so the target branch never has some
    # of them without the others.
    proposed =
      case proposals do
        [] ->
          []

        [one] ->
          [Changes.propose(one)]

        many ->
          group = %{
            intent: "Merge branch #{from} into #{into}",
            branch: into,
            behaviour_change: true,
            proposer: Keyword.get(opts, :proposer, %{kind: :iex, client: nil}),
            units: Enum.map(many, &Map.take(&1, [:unit, :unit_source, :spec_source, :trigger]))
          }

          case Changes.propose_group(group) do
            {:ok, results} -> for {change, report} <- results, do: {:ok, change, report}
            {:error, reason} -> [{:error, reason}]
          end
      end

    %{
      merge: merge_id,
      from: from,
      into: into,
      changes: for({:ok, change, _report} <- proposed, do: change),
      refused: for({:error, reason} <- proposed, do: reason),
      conflicts: conflicts,
      combined: Enum.map(combined, &elem(&1, 0)),
      only_into: for(%{status: :into, unit: u} <- diff, do: u)
    }
  end

  defp merge_bases(from, into) do
    if parent(from) == into, do: bases(from, into), else: flip(bases(into, from))
  end

  # Each part changed on both sides combined with the target's version.
  defp combine_parts(parts, bases) do
    Enum.reduce_while(parts, {:ok, %{}, %{}}, fn
      %{side: :from, module: m, from: f}, {:ok, sources, texts} ->
        {:cont, {:ok, Map.put(sources, m, f), texts}}

      %{side: :conflict, module: m, from: f, into: i}, {:ok, sources, texts} ->
        {base, _} = Map.get(bases, m, {nil, nil})

        with true <- is_binary(f) and is_binary(i),
             {:ok, %Version{ast: theirs}} when theirs != nil <- Ledger.version(m, f),
             {:ok, ast} <- Theseus.Combine.versions(m, base, i, theirs) do
          {:cont, {:ok, Map.put(sources, m, f), Map.put(texts, m, Version.render(ast))}}
        else
          {:conflict, what} -> {:halt, {:conflict, what}}
          _ -> {:halt, {:conflict, [inspect(m)]}}
        end

      _same_or_into, acc ->
        {:cont, acc}
    end)
  end

  @doc false
  def merge_proposal(unit, sources, from, into, merge_id, opts, texts \\ %{}) do
    source = fn module ->
      with nil <- texts[module],
           hash when is_binary(hash) <- sources[module],
           {:ok, %Version{source: text}} <- Ledger.version(module, hash) do
        text
      else
        text when is_binary(text) -> text
        _ -> nil
      end
    end

    %{
      unit: unit,
      branch: into,
      intent: "Merge #{inspect(unit)} from branch #{from} into #{into}",
      unit_source: source.(unit),
      spec_source: source.(Unit.spec_module(unit)),
      behaviour_change: true,
      proposer: Keyword.get(opts, :proposer, %{kind: :iex, client: nil}),
      trigger: %{
        kind: :merge,
        payload: %{from: from, into: into, merge: merge_id, sources: sources},
        untrusted: false
      }
    }
  end
end
