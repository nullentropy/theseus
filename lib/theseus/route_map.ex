defmodule Theseus.RouteMap do
  @moduledoc """
  The paths an app answers, read from its endpoint units' syntax trees, for
  the review site. No code is shown: each route is a method, a path and the
  unit that answers it.

  A route is a function clause of an endpoint unit (any name, such as
  `handle/1` or a private `route/2`) whose first argument is a map pattern
  with a `path` key that is a list. Literal segments show as they are,
  variables as `:name`, a variable limited by `when x in [...]` or `in
  @attribute` as `{a,b}`, and a tail `| _` as `...`. A clause whose body
  hands the request to another unit (`Theseus.call(Other, :handle, ...)`,
  or a local function called with a module as its first argument) is a
  hand-on to that unit. Patterns on `user: nil` or `viewer: nil` mark routes
  for people who are signed out, and `viewer: %{role: "admin"}` routes for
  admins. A pattern with an `htmx` key marks a route that answers htmx
  requests for part of a page. Anything the patterns do not show, such as a check inside the
  clause, is not shown here either.
  """

  alias Theseus.{Ledger, Version}

  @type route :: %{
          method: String.t(),
          path: String.t(),
          unit: module(),
          who: String.t() | nil,
          htmx: boolean(),
          hands_on: module() | nil
        }

  @doc """
  The routes of a branch's endpoint units, the root's first, then the units
  it hands on to, in the order it names them, then any others.
  """
  @spec routes(String.t(), module() | nil) :: [route()]
  def routes(branch, root) do
    endpoints =
      for %{kind: :endpoint, module: m, current_version: h} <- Theseus.Branches.units(branch),
          {:ok, %Version{ast: ast}} <- [Ledger.version(m, h)],
          into: %{},
          do: {m, ast}

    # Only endpoint units count as hand-ons.
    by_unit =
      Map.new(endpoints, fn {m, ast} ->
        {m,
         for(
           r <- of_ast(m, ast),
           do: %{r | hands_on: if(Map.has_key?(endpoints, r.hands_on), do: r.hands_on)}
         )}
      end)

    order = order(root, by_unit, Map.keys(endpoints) |> Enum.sort())
    Enum.flat_map(order, &Map.get(by_unit, &1, []))
  end

  defp order(nil, _by_unit, all), do: all

  defp order(root, by_unit, all) do
    handed = fn m ->
      for(r <- Map.get(by_unit, m, []), r.hands_on, do: r.hands_on) |> Enum.uniq()
    end

    walk = walk([root], handed, [])
    walk ++ (all -- walk)
  end

  defp walk([], _handed, seen), do: Enum.reverse(seen)

  defp walk([m | rest], handed, seen) do
    if m in seen, do: walk(rest, handed, seen), else: walk(handed.(m) ++ rest, handed, [m | seen])
  end

  @doc "The routes of one endpoint unit, from its syntax tree, in source order."
  @spec of_ast(module(), Macro.t()) :: [route()]
  def of_ast(unit, {:defmodule, _, [_name, [do: body]]}) do
    statements = block(body)
    attributes = for {:@, _, [{name, _, [value]}]} <- statements, into: %{}, do: {name, value}

    # Clauses in order, per function: once a clause without a path refuses
    # everyone but admins, the later clauses of that function see admins
    # only.
    {routes, _gated} =
      Enum.flat_map_reduce(statements, MapSet.new(), fn
        {kind, _, [head | rest]}, gated when kind in [:def, :defp] ->
          {args, guard} = head_parts(head)
          name = head_name(head)
          fields = match?([_ | _], args) && map_pattern(hd(args))

          cond do
            is_map(fields) and is_list(fields[:path]) ->
              body = rest |> List.first() |> clause_body()
              who = who(fields, args, guard) || if(MapSet.member?(gated, name), do: "admins")

              route = %{
                method: method(fields[:method]),
                path: render(fields[:path], constraints(guard, attributes)),
                unit: unit,
                who: who,
                htmx: Map.has_key?(fields, :htmx),
                hands_on: hands_on(body)
              }

              {[route], gated}

            is_map(fields) and not Map.has_key?(fields, :path) and refuses_non_admins?(guard) ->
              {[], MapSet.put(gated, name)}

            true ->
              {[], gated}
          end

        _statement, gated ->
          {[], gated}
      end)

    # A later clause for a method and path an earlier one took handles
    # everyone the earlier ones did not.
    {routes, _seen} =
      Enum.map_reduce(routes, MapSet.new(), fn r, seen ->
        key = {r.method, r.path, r.htmx}

        r =
          if MapSet.member?(seen, key) and r.who == nil, do: %{r | who: "everyone else"}, else: r

        {r, MapSet.put(seen, key)}
      end)

    routes
  end

  def of_ast(_unit, _ast), do: []

  defp block({:__block__, _, statements}), do: statements
  defp block(statement), do: [statement]

  defp head_parts({:when, _, [{_name, _, args}, guard]}) when is_list(args), do: {args, guard}
  defp head_parts({_name, _, args}) when is_list(args), do: {args, nil}
  defp head_parts(_), do: {[], nil}

  defp head_name({:when, _, [{name, _, _}, _guard]}), do: name
  defp head_name({name, _, _}), do: name

  # Only a guard that is exactly `role != "admin"`: one with more conditions
  # (`and method != "GET"`, say) does not keep everyone else out.
  defp refuses_non_admins?({:!=, _, [{var, _, ctx}, "admin"]}) when is_atom(var) and is_atom(ctx),
    do: true

  defp refuses_non_admins?(_guard), do: false

  defp clause_body(do: body), do: body
  defp clause_body(kw) when is_list(kw), do: Keyword.get(kw, :do)
  defp clause_body(_), do: nil

  # The map in `%{...}`, `%{...} = var` or `var = %{...}`, as atom keys to
  # pattern terms.
  defp map_pattern({:%{}, _, pairs}), do: Map.new(for {k, v} <- pairs, is_atom(k), do: {k, v})
  defp map_pattern({:=, _, [left, right]}), do: map_pattern(left) || map_pattern(right)
  defp map_pattern(_), do: nil

  defp method(m) when is_binary(m), do: m
  defp method(_), do: "any"

  # Variables limited by `x in [...]` or `x in @attribute` in the guard.
  defp constraints(nil, _attributes), do: %{}

  defp constraints(guard, attributes) do
    {_, found} =
      Macro.prewalk(guard, %{}, fn
        # `x not in [...]` says what x is not; it shows nothing.
        {:not, _, [_]}, acc ->
          {:skipped, acc}

        {:in, _, [{var, _, ctx}, list]} = node, acc when is_atom(var) and is_atom(ctx) ->
          values =
            case list do
              l when is_list(l) -> l
              {:@, _, [{name, _, _}]} -> Map.get(attributes, name)
              _ -> nil
            end

          if is_list(values) and Enum.all?(values, &is_binary/1),
            do: {node, Map.put(acc, var, values)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp render(path, constraints) do
    "/" <> Enum.map_join(segments(path), "/", &segment(&1, constraints))
  end

  defp segments([{:|, _, [head, _tail]}]), do: [head, :rest]
  defp segments([first | rest]), do: [first | segments(rest)]
  defp segments([]), do: []

  defp segment(:rest, _c), do: "..."
  defp segment(literal, _c) when is_binary(literal), do: literal

  defp segment({var, _, ctx}, constraints) when is_atom(var) and is_atom(ctx) do
    case constraints[var] do
      nil -> ":" <> (var |> Atom.to_string() |> String.trim_leading("_"))
      values -> "{" <> Enum.join(values, ",") <> "}"
    end
  end

  defp segment(_other, _c), do: ":?"

  defp who(fields, args, guard) do
    cond do
      fields[:user] == nil and Map.has_key?(fields, :user) -> "signed out"
      fields[:viewer] == nil and Map.has_key?(fields, :viewer) -> "signed out"
      admin_pattern?(fields[:viewer]) or Enum.any?(tl(args), &admin_pattern?/1) -> "admins"
      refuses_non_admins?(guard) -> "everyone but admins"
      true -> nil
    end
  end

  defp admin_pattern?(pattern) do
    case map_pattern(pattern) do
      %{role: "admin"} -> true
      _ -> false
    end
  end

  # The unit a clause hands the request to, if any.
  defp hands_on(nil), do: nil

  defp hands_on(body) do
    {_, found} =
      Macro.prewalk(body, nil, fn
        {{:., _, [{:__aliases__, _, [:Theseus]}, :call]}, _, [target, :handle | _]} = node, nil ->
          {node, module_of(target)}

        {name, _, [target | _]} = node, nil
        when is_atom(name) and name not in [:__aliases__, :.] ->
          {node, module_of(target)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp module_of({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts)
  end

  defp module_of(_), do: nil
end
