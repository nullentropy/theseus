defmodule Theseus.Combine do
  @moduledoc """
  Combines two edits of one unit that started from the same version, when
  they change different parts of it (step 4 of `docs/team-design.md`).

  A unit is split into items: each function with all its clauses and the
  `@doc`, `@spec` and `@impl` before it, each other module attribute, each
  `use`, `alias`, `import` and `require`, and anything else in order. A
  spec's rules are items too, by kind and name, and its prose is one. Each
  item is merged three ways: what only one side changed is taken from that
  side, what both changed the same way is kept, and what both changed
  differently is a conflict. A schema unit's tables are merged as data:
  both sides only add tables, columns and indexes, so the result has all
  of them, unless both define one column differently.

  When a change is approved, the held changes to the same units on the same
  branch became stale. This server tries to combine each with the approved
  version; when it can, it proposes the combined version, which is
  validated like any change and held for a person, and rejects the stale
  one with a note saying which change replaced it. When both changed the
  same parts, it rejects the stale one saying which, so its proposer can
  propose it again on top. A group is combined as a group. Merges between branches combine their conflicts the same way
  (`Theseus.Branches.merge/3`).
  """

  use GenServer
  require Logger

  alias Theseus.{Change, Changes, Ledger, Unit, Version}

  @attached [:doc, :spec, :impl, :deprecated]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # From Theseus.Changes after a change is promoted.
  def promoted(%Change{} = change) do
    if enabled?() and Process.whereis(__MODULE__),
      do: GenServer.cast(__MODULE__, {:promoted, change})

    :ok
  end

  @doc "Whether held changes are combined after an approval (config `:combine, enabled:`)."
  def enabled?, do: Keyword.get(Application.get_env(:theseus, :combine, []), :enabled, true)

  @doc "Waits until the combinations so far are proposed (for tests)."
  def sync, do: GenServer.call(__MODULE__, :sync, 300_000)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:promoted, change}, state) do
    try do
      combine_after(change)
    rescue
      e -> Logger.warning("combining after #{change.id}: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  ## Combining two versions

  @doc """
  Combines `theirs` (a syntax tree) with `ours` (a version hash), both
  edits of `base` (a version hash) of `module`: `{:ok, ast}` or
  `{:conflict, [what]}`, naming the parts both changed.
  """
  @spec versions(module(), String.t() | nil, String.t() | nil, Macro.t()) ::
          {:ok, Macro.t()} | {:conflict, [String.t()]}
  def versions(_module, base, base, theirs), do: {:ok, theirs}

  def versions(module, base, ours, theirs) do
    with {:ok, %Version{ast: base_ast}} when base_ast != nil <- version(module, base),
         {:ok, %Version{ast: ours_ast}} when ours_ast != nil <- version(module, ours) do
      asts(base_ast, ours_ast, theirs)
    else
      _ -> {:conflict, ["#{inspect(module)} was created on both sides"]}
    end
  end

  defp version(_module, nil), do: :error
  defp version(module, hash), do: Ledger.version(module, hash)

  @doc "Combines two edited module syntax trees with their common base."
  @spec asts(Macro.t(), Macro.t(), Macro.t()) :: {:ok, Macro.t()} | {:conflict, [String.t()]}
  def asts(base, ours, theirs) do
    {:defmodule, meta, [name, [do: _]]} = ours

    case merge(items(base), items(ours), items(theirs)) do
      {:ok, merged} ->
        body = merged |> Enum.flat_map(&statements(elem(&1, 1))) |> block()
        {:ok, {:defmodule, meta, [name, [do: body]]}}

      {:conflict, keys} ->
        {:conflict, Enum.map(keys, &describe_key/1)}
    end
  end

  defp block([one]), do: one
  defp block(statements), do: {:__block__, [], statements}

  # Three-way merge of keyed items, in ours' order, with what only theirs
  # added placed after the item it follows there.
  defp merge(base, ours, theirs) do
    b = Map.new(base)
    o = Map.new(ours)
    t = Map.new(theirs)
    keys = order(Enum.map(ours, &elem(&1, 0)), Enum.map(theirs, &elem(&1, 0)))

    {items, conflicts} =
      Enum.reduce(keys, {[], []}, fn key, {items, conflicts} ->
        case pick(key, b[key], o[key], t[key]) do
          {:ok, nil} -> {items, conflicts}
          {:ok, node} -> {[{key, node} | items], conflicts}
          :conflict -> {items, [key | conflicts]}
        end
      end)

    if conflicts == [], do: {:ok, Enum.reverse(items)}, else: {:conflict, Enum.reverse(conflicts)}
  end

  defp pick(_key, _b, same, same), do: {:ok, same}
  defp pick(_key, same, same, theirs), do: {:ok, theirs}
  defp pick(_key, same, ours, same), do: {:ok, ours}

  # A spec block's rules are merged one by one.
  defp pick(:spec_block, b, o, t) when b != nil and o != nil and t != nil do
    {call, meta, args_o} = o
    {_, _, args_b} = b
    {_, _, args_t} = t

    with [unit, opts_o, [do: body_o]] <- spec_args(args_o),
         [_, opts_b, [do: body_b]] <- spec_args(args_b),
         [_, opts_t, [do: body_t]] <- spec_args(args_t),
         {:ok, opts} <- pick(:spec_options, opts_b, opts_o, opts_t),
         {:ok, merged} <- merge(rules(body_b), rules(body_o), rules(body_t)) do
      body = merged |> Enum.flat_map(&statements(elem(&1, 1))) |> block()
      args = if opts == [], do: [unit, [do: body]], else: [unit, opts, [do: body]]
      {:ok, {call, meta, args}}
    else
      {:conflict, _} -> :conflict
      _ -> :conflict
    end
  end

  # A schema unit's tables: the union of what both sides added.
  defp pick({:def, :tables, 0}, b, o, t) when b != nil and o != nil and t != nil do
    with {:ok, vb} <- def_value(b),
         {:ok, vo} <- def_value(o),
         {:ok, vt} <- def_value(t),
         {:ok, merged} <- union_map(vb, vo, vt, 0) do
      {:ok, with_value(o, merged)}
    else
      _ -> :conflict
    end
  end

  defp pick(_key, _b, _o, _t), do: :conflict

  defp spec_args([unit, [do: _] = body]), do: [unit, [], body]
  defp spec_args([unit, opts, [do: _] = body]), do: [unit, opts, body]
  defp spec_args(_), do: nil

  # Keys of both lists: ours in order, then each key only theirs has, placed
  # after the key before it in theirs.
  defp order(ours, theirs) do
    Enum.reduce(Enum.with_index(theirs), ours, fn {key, i}, acc ->
      if key in acc do
        acc
      else
        before = theirs |> Enum.take(i) |> Enum.reverse() |> Enum.find(&(&1 in acc))

        case before && Enum.find_index(acc, &(&1 == before)) do
          nil -> [key | acc]
          at -> List.insert_at(acc, at + 1, key)
        end
      end
    end)
  end

  ## Items

  @doc false
  # A module's top-level statements as keyed items.
  def items({:defmodule, _, [_name, [do: body]]}) do
    statements = statements(body)

    {items, pending, _counts} =
      Enum.reduce(statements, {[], [], %{}}, fn node, {items, pending, counts} ->
        case node do
          {:@, _, [{attr, _, _}]} when attr in @attached ->
            {items, pending ++ [node], counts}

          _ ->
            {key, counts} = key(node, counts)

            case {key, items} do
              # Clauses of one function are one item, with their attributes.
              {{:def, _, _} = k, [{k, previous} | rest]} ->
                {[{k, previous ++ pending ++ [node]} | rest], [], counts}

              _ ->
                {[{key, pending ++ [node]} | items], [], counts}
            end
        end
      end)

    items = Enum.reverse(items)
    # Attributes at the very end belong to nothing; keep them as one item.
    items = if pending == [], do: items, else: items ++ [{:trailing, pending}]
    Enum.map(items, fn {k, nodes} -> {k, unwrap(nodes)} end)
  end

  defp unwrap([one]), do: one
  defp unwrap(nodes), do: {:__block__, [], nodes}

  defp statements({:__block__, _, statements}), do: statements
  defp statements(nil), do: []
  defp statements(one), do: [one]

  defp key({kind, _, [head | _]}, counts) when kind in [:def, :defp, :defmacro, :defmacrop] do
    {name, arity} = signature(head)
    {{:def, name, arity}, counts}
  end

  defp key({:spec, _, [_unit | _]}, counts), do: {:spec_block, counts}
  defp key({:@, _, [{:moduledoc, _, _}]}, counts), do: {{:attr, :moduledoc, 0}, counts}

  defp key({:@, _, [{name, _, _}]}, counts) do
    n = Map.get(counts, {:attr, name}, 0)
    {{:attr, name, n}, Map.put(counts, {:attr, name}, n + 1)}
  end

  defp key({directive, _, _} = node, counts)
       when directive in [:use, :alias, :import, :require],
       do: {{directive, Macro.to_string(node)}, counts}

  defp key(node, counts) do
    n = Map.get(counts, :other, 0)
    {{:other, n, Macro.to_string(node) |> String.slice(0, 60)}, Map.put(counts, :other, n + 1)}
  end

  defp signature({:when, _, [head | _]}), do: signature(head)
  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp signature({name, _, _}) when is_atom(name), do: {name, 0}

  # A spec block's body as keyed rules.
  defp rules(body) do
    {items, _} =
      Enum.reduce(statements(body), {[], 0}, fn node, {items, n} ->
        case node do
          {kind, _, [name | _]}
          when kind in [:example, :property, :invariant] and is_binary(name) ->
            {[{{kind, name}, node} | items], n}

          {:prose, _, _} ->
            {[{:prose, node} | items], n}

          {kind, _, _} when kind in [:equivalence] ->
            {[{{kind, n}, node} | items], n + 1}

          other ->
            {[{{:other, n}, other} | items], n + 1}
        end
      end)

    Enum.reverse(items)
  end

  ## Schema tables as data

  defp def_value({kind, _, [_head, [do: value]]}) when kind in [:def, :defp], do: {:ok, value}
  defp def_value(_), do: :error

  defp with_value({kind, meta, [head, [do: _]]}, value), do: {kind, meta, [head, [do: value]]}

  # Map literals: keys from both sides; a key both changed is merged one
  # level down (tables, then their columns). Index lists are joined.
  defp union_map({:%{}, meta, b}, {:%{}, _, o}, {:%{}, _, t}, depth) when depth <= 2 do
    keys = order(Keyword.keys(o), Keyword.keys(t))

    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case union_value(key, Keyword.get(b, key), Keyword.get(o, key), Keyword.get(t, key), depth) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, v} -> {:cont, {:ok, acc ++ [{key, v}]}}
        :conflict -> {:halt, :conflict}
      end
    end)
    |> case do
      {:ok, kv} -> {:ok, {:%{}, meta, kv}}
      :conflict -> :conflict
    end
  end

  defp union_map(_b, _o, _t, _depth), do: :conflict

  defp union_value(_key, _b, same, same, _depth), do: {:ok, same}
  defp union_value(_key, same, same, theirs, _depth), do: {:ok, theirs}
  defp union_value(_key, same, ours, same, _depth), do: {:ok, ours}

  defp union_value(:indexes, b, o, t, _depth) when is_list(o) and is_list(t),
    do: {:ok, Enum.uniq(o ++ (t -- (b || [])))}

  defp union_value(_key, b, {:%{}, _, _} = o, {:%{}, _, _} = t, depth),
    do: union_map(b || {:%{}, [], []}, o, t, depth + 1)

  defp union_value(_key, _b, _o, _t, _depth), do: :conflict

  defp describe_key({:def, name, arity}), do: "#{name}/#{arity}"
  defp describe_key({:attr, name, _}), do: "@#{name}"

  defp describe_key({directive, text}) when directive in [:use, :alias, :import, :require],
    do: text

  defp describe_key({kind, name}) when kind in [:example, :property, :invariant],
    do: "#{kind} #{inspect(name)}"

  defp describe_key(:prose), do: "the spec's prose"
  defp describe_key(:spec_block), do: "the spec's options"
  defp describe_key({:other, _, text}), do: text
  defp describe_key(other), do: inspect(other)

  ## After a promotion

  # The held changes on the promoted change's branch that touch a module it
  # changed, and are now stale, combined with the new versions.
  defp combine_after(%Change{} = promoted) do
    modules = Enum.map(promoted.candidates, & &1.unit)

    stale =
      for {c, _r} <- Changes.list(branch: promoted.branch, limit: :all),
          c.status in [:held, :shadowing],
          c.id != promoted.id,
          c.removes == nil,
          c.trigger.kind not in [:crash, :consolidate],
          Enum.any?(c.candidates, &(&1.unit in modules and stale?(&1, c.branch))),
          do: c

    stale
    |> Enum.uniq_by(&(&1.group || &1.id))
    |> Enum.each(&combine_change(&1, promoted))
  end

  defp stale?(%Version{unit: module, parent: parent}, branch),
    do: Ledger.current(module, branch) != parent

  defp combine_change(%Change{group: nil} = change, promoted) do
    case combined_entry(change) do
      {:ok, entry} ->
        case Changes.propose(Map.merge(entry, shared(change, promoted, [change.id]))) do
          {:ok, new, _report} -> replaced([change], [new], promoted)
          {:error, why} -> Logger.info("could not combine #{change.id}: #{inspect(why)}")
        end

      {:conflict, what} ->
        conflicting([change], what, promoted)
    end
  end

  defp combine_change(%Change{group: group} = change, promoted) do
    members = for {c, _} <- Changes.group(group), c.status in [:held, :shadowing], do: c

    entries =
      Enum.reduce_while(members, {:ok, []}, fn c, {:ok, acc} ->
        case combined_entry(c) do
          {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
          other -> {:halt, other}
        end
      end)

    case entries do
      {:ok, units} ->
        proposal = Map.put(shared(change, promoted, Enum.map(members, & &1.id)), :units, units)

        case Changes.propose_group(proposal) do
          {:ok, results} -> replaced(members, Enum.map(results, &elem(&1, 0)), promoted)
          {:error, why} -> Logger.info("could not combine group #{group}: #{inspect(why)}")
        end

      {:conflict, what} ->
        conflicting(members, what, promoted)
    end
  end

  defp shared(change, promoted, ids) do
    %{
      intent: change.intent,
      rationale: change.rationale,
      behaviour_change: change.behaviour_change,
      proposer: change.proposer,
      branch: change.branch,
      trigger: %{
        kind: :combined,
        payload: %{replaces: ids, onto: promoted.id},
        untrusted: false
      }
    }
  end

  # The stale change's candidates combined with the current versions, as
  # proposal sources.
  defp combined_entry(%Change{} = c) do
    Enum.reduce_while(c.candidates, {:ok, %{unit: inspect(c.unit)}}, fn v, {:ok, entry} ->
      current = Ledger.current(v.unit, c.branch)

      case versions(v.unit, v.parent, current, v.ast) do
        {:ok, ast} ->
          key = if Unit.spec_name?(v.unit), do: :spec_source, else: :unit_source
          {:cont, {:ok, Map.put(entry, key, Version.render(ast))}}

        {:conflict, what} ->
          {:halt, {:conflict, what}}
      end
    end)
  end

  # Both changed the same parts: the stale change cannot be approved, so it
  # is rejected now, saying what to do.
  defp conflicting(changes, what, promoted) do
    Theseus.Notices.not_combined(hd(changes), what, promoted.id)

    for c <- changes do
      Changes.reject(
        c.id,
        "#{promoted.id} was approved first and changed the same parts (#{Enum.join(what, ", ")}); propose it again on top of the current version",
        actor: :system
      )
    end

    :ok
  end

  defp replaced(old, new, promoted) do
    ids = Enum.map_join(new, ", ", & &1.id)
    Theseus.Notices.combined(hd(old), ids, promoted.id)

    for c <- old do
      Changes.reject(
        c.id,
        "combined with #{promoted.id}, which was approved first: see #{ids}",
        actor: :system
      )
    end

    :ok
  end

  @doc """
  Why a stale change cannot be combined with its unit's current versions:
  the parts both changed, or nil when it can be.
  """
  @spec conflicts(Change.t()) :: [String.t()] | nil
  def conflicts(%Change{} = c) do
    case combined_entry(c) do
      {:ok, _} -> nil
      {:conflict, what} -> what
    end
  end
end
