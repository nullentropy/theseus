defmodule Theseus.Validator.Static do
  @moduledoc """
  Rejects candidate code that reaches outside the unit. This is a backstop,
  not the security boundary: candidates also run renamed, under timeouts,
  and only against spec and trace inputs until a person approves them.

  Remote calls, aliases and module-naming atoms must name a module on the
  allowlist, except an atom that can only be a function's name: the second
  argument of `Theseus.call/3`, and the first of `call.(...)` and
  `app.(...)` in a spec. Dynamic dispatch (`mod.fun()`, `apply`, `&mod.fun/1`) and
  atom creation from strings are rejected, because they would get around the
  allowlist. `x.y` without parentheses is allowed as map field access.
  """

  alias Theseus.{Unit, Version}

  @max_lines 200
  # Specs are mostly examples and named rules, and an endpoint's grows with
  # every route, so they get more room.
  # A spec repeats its request and person builders, and the root's spec
  # checks flows through the whole app, so it has room for both.
  @max_spec_lines 600

  # Units are deterministic, so recorded calls replay to the same results:
  # no clocks and no randomness. The time comes in as an argument.
  @allowed %{
    Kernel => {:except, [:apply, :spawn, :spawn_link, :spawn_monitor, :send, :binding, :dbg]},
    String => {:except, [:to_atom, :to_existing_atom]},
    List => {:except, [:to_atom, :to_existing_atom]},
    Enum => {:except, [:random, :shuffle, :take_random]},
    Map => :all,
    MapSet => :all,
    Keyword => :all,
    Tuple => :all,
    Integer => :all,
    Float => :all,
    Atom => :all,
    Regex => :all,
    Date => {:except, [:utc_today]},
    Time => {:except, [:utc_now]},
    DateTime => {:except, [:utc_now, :now, :now!]},
    NaiveDateTime => {:except, [:utc_now, :local_now]},
    Calendar => :all,
    Base => :all,
    Bitwise => :all,
    Range => :all,
    Access => :all,
    Stream => :all,
    URI => :all,
    JSON => :all,
    Plug.HTML => {:only, [:html_escape, :html_escape_to_iodata]},
    :math => :all,
    :binary => :all,
    :lists => :all,
    :maps => :all,
    :string => :all,
    :unicode => :all,
    :queue => :all,
    :sets => :all,
    :ordsets => :all,
    :orddict => :all,
    :gb_trees => :all,
    :gb_sets => :all,
    :proplists => :all
  }

  @spec_allowed %{
    Theseus.Spec => :all,
    Theseus.Spec.DSL => :all,
    StreamData => :all,
    # Specs give endpoint units rows to read.
    Theseus.Store => {:only, [:with_rows, :id]}
  }

  # Endpoint units read the app's data; their writes are returned as data.
  @store_allowed %{Theseus.Store => {:only, [:get, :all, :count, :aggregate, :id]}}

  # Server units hold state in a GenServer. They talk to it only through
  # GenServer; spawn, send and receive stay out.
  @server_allowed %{
    GenServer => {:only, [:start_link, :call, :cast, :reply, :stop, :whereis]}
  }

  # Endpoint units call other units, and pure and server units call pure
  # units, only through Theseus.call/3.
  @call_allowed %{Theseus => {:only, [:call]}}

  @denied_locals [
    :apply,
    :spawn,
    :spawn_link,
    :spawn_monitor,
    :send,
    :receive,
    :binding,
    :dbg,
    :alias,
    :defdelegate,
    :defprotocol,
    :defimpl,
    :defmodule
  ]

  @denied_attributes [
    :on_load,
    :after_compile,
    :after_verify,
    :before_compile,
    :on_definition,
    :compile,
    :vsn,
    :external_resource
  ]

  @doc """
  Returns `:ok` or `{:error, violations}` for a unit or spec version. `kind`
  is the unit's kind; by default it is inferred from the source. Option
  `:units` lists the units a unit may name, to call them through
  `Theseus.call/3`: every unit for an endpoint, pure units for a pure or
  server unit.
  """
  @spec check(Version.t(), Unit.kind() | nil, keyword()) :: :ok | {:error, [String.t()]}
  def check(%Version{unit: module, ast: ast, source: source}, kind \\ nil, opts \\ []) do
    kind = kind || Unit.infer_kind(module, ast)

    {allowed, named, uses} =
      case kind do
        # A spec may name the unit it describes.
        :spec ->
          {Map.merge(@allowed, @spec_allowed), [Unit.specified_unit(module)], [Theseus.Spec]}

        :server ->
          {@allowed |> Map.merge(@server_allowed) |> Map.merge(@call_allowed), [], [GenServer]}

        :endpoint ->
          {@allowed |> Map.merge(@call_allowed) |> Map.merge(@store_allowed), [],
           [Theseus.Endpoint]}

        # A store unit keeps a table's reads and writes for the endpoint
        # units: their rules, without routes.
        :store ->
          {@allowed |> Map.merge(@call_allowed) |> Map.merge(@store_allowed), [], [Theseus.Store]}

        # A schema unit is a pure unit that declares tables (Theseus.Schema).
        :pure ->
          {Map.merge(@allowed, @call_allowed), [],
           [Theseus.Schema, Theseus.Services, Theseus.Seed]}
      end

    units =
      if kind in [:endpoint, :store, :server, :pure],
        do: Keyword.get(opts, :units, []) -- [module],
        else: []

    ctx = %{self: module, allowed: allowed, named: named, uses: uses, units: units, kind: kind}

    {:defmodule, _, [_name, [do: body]]} = ast
    lines = source |> String.split("\n") |> length()

    violations =
      walk(body, ctx, []) ++
        if(lines > max_lines(length_kind(kind, ast)),
          do: [too_long(length_kind(kind, ast), lines)],
          else: []
        ) ++
        if(kind == :server and not defines?(body, :code_change, 3),
          do: ["a server unit must define code_change/3 to migrate its state when it changes"],
          else: []
        ) ++ store_tables(body)

    case violations |> Enum.reverse() |> Enum.uniq() do
      [] -> :ok
      list -> {:error, list}
    end
  end

  # The store's reads name their table with a literal atom, so the engine
  # can tell which tables a unit reads.
  defp store_tables(body) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Theseus, :Store]}, fun]}, _, [table | _]} = node, acc
        when fun in [:get, :all, :count, :aggregate] and not is_atom(table) ->
          {node,
           ["Theseus.Store.#{fun} names its table with a literal atom, such as :activity" | acc]}

        # A join names its table with a literal atom too.
        {{:., _, [{:__aliases__, _, [:Theseus, :Store]}, fun]}, _, [_table, opts]} = node, acc
        when fun in [:all, :count, :aggregate] and is_list(opts) ->
          bad =
            for {:join, joins} <- opts,
                not (is_list(joins) and
                       Enum.all?(joins, &literal_join?/1)),
                do:
                  "Theseus.Store.#{fun} joins with join: [name: {:table, :column}], all literal atoms"

          {node, bad ++ acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp literal_join?({_, {t, c}}) when is_atom(t) and is_atom(c), do: true
  defp literal_join?({_, {t, {j, c}}}) when is_atom(t) and is_atom(j) and is_atom(c), do: true
  defp literal_join?(_join), do: false

  # `Theseus.call(Unit, :name, args)`: the function's name is a name, not a
  # module, even when an Erlang module has it (`:shell`, `:file`).
  defp walk({{:., _, [{:__aliases__, _, [:Theseus]}, :call]}, _, [unit, name, args]}, ctx, acc)
       when is_atom(name) do
    walk([unit, args], ctx, check_call(Theseus, :call, ctx, acc))
  end

  # In a spec, `call.(:name, args)` and `app.(:name, args)` call the unit
  # under test and the app by function name.
  defp walk({{:., _, [{harness, _, context}]}, _, [name | args]}, %{kind: :spec} = ctx, acc)
       when harness in [:call, :app] and is_atom(context) and is_atom(name) do
    walk(args, ctx, acc)
  end

  # Remote call or field access: `target.fun(args)` or `target.fun`.
  defp walk({{:., _, [target, fun]}, meta, args}, ctx, acc) when is_atom(fun) and is_list(args) do
    acc =
      case resolve(target) do
        {:module, mod} ->
          check_call(mod, fun, ctx, acc)

        :self ->
          acc

        :dynamic ->
          if meta[:no_parens] == true and args == [],
            do: walk(target, ctx, acc),
            else: [
              "dynamic call #{Macro.to_string(target)}.#{fun}(...): call modules by name" | acc
            ]
      end

    walk(args, ctx, acc)
  end

  # Anonymous function call: `fun.(args)`.
  defp walk({{:., _, [fun]}, _, args}, ctx, acc), do: walk([fun | args], ctx, acc)

  # Capture of a remote function: `&mod.fun/arity`.
  defp walk({:&, _, [{:/, _, [{{:., _, [target, fun]}, _, []}, _arity]}]}, ctx, acc) do
    case resolve(target) do
      {:module, mod} ->
        check_call(mod, fun, ctx, acc)

      :self ->
        acc

      :dynamic ->
        ["dynamic capture &#{Macro.to_string(target)}.#{fun}: capture modules by name" | acc]
    end
  end

  # A name built on __MODULE__ (`__MODULE__.Admin`) would point at the
  # wrong module once the unit runs under a candidate name, and hides the
  # reference from the dependents stage; one built on a variable or an
  # attribute (`x.Foo`) is a module chosen at run time.
  defp walk({:__aliases__, _, _} = alias_ast, ctx, acc) do
    case resolve(alias_ast) do
      {:module, mod} ->
        check_module(mod, ctx, acc)

      :dynamic ->
        [
          "#{Macro.to_string(alias_ast)}: write the module's full name, " <>
            "not a name built on __MODULE__ or a variable"
          | acc
        ]

      :self ->
        acc
    end
  end

  defp walk({:@, _, [{name, _, value}]}, ctx, acc) when is_atom(name) do
    acc = if name in @denied_attributes, do: ["@#{name} is not allowed" | acc], else: acc
    walk(value, ctx, acc)
  end

  defp walk({:use, _, [target | opts]}, ctx, acc) do
    acc =
      case resolve(target) do
        {:module, mod} ->
          if mod in ctx.uses, do: acc, else: ["use #{inspect(mod)} is not allowed" | acc]

        _ ->
          ["use of a non-literal module is not allowed" | acc]
      end

    walk(opts, ctx, acc)
  end

  defp walk({directive, _, [target | opts]}, ctx, acc) when directive in [:import, :require] do
    acc =
      case resolve(target) do
        {:module, mod} -> check_module(mod, ctx, acc)
        _ -> ["#{directive} of a non-literal module is not allowed" | acc]
      end

    walk(opts, ctx, acc)
  end

  defp walk({form, _, args}, ctx, acc) when is_atom(form) do
    acc = if form in @denied_locals, do: ["#{form} is not allowed in units" | acc], else: acc
    if is_list(args), do: walk(args, ctx, acc), else: acc
  end

  defp walk({form, _, args}, ctx, acc) do
    acc = walk(form, ctx, acc)
    if is_list(args), do: walk(args, ctx, acc), else: acc
  end

  # Keyword lists: keys are names, not module references.
  defp walk([{key, _} | _] = list, ctx, acc) when is_atom(key) do
    Enum.reduce(list, acc, fn
      {k, v}, acc when is_atom(k) -> walk(v, ctx, acc)
      other, acc -> walk(other, ctx, acc)
    end)
  end

  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))
  defp walk({a, b}, ctx, acc), do: walk(b, ctx, walk(a, ctx, acc))

  # An atom literal that names a loaded module could be called through a
  # variable (`m = :os; m.getpid`), so it must be an allowed module.
  defp walk(atom, ctx, acc) when is_atom(atom) and atom not in [nil, true, false] do
    if module?(atom), do: check_module(atom, ctx, acc), else: acc
  end

  defp walk(_literal, _ctx, acc), do: acc

  defp check_call(mod, fun, ctx, acc) do
    acc =
      if mod in ctx.units,
        do: ["call #{inspect(mod)} through Theseus.call(#{inspect(mod)}, :#{fun}, [args])" | acc],
        else: check_module(mod, ctx, acc)

    case Map.get(ctx.allowed, mod) do
      {:except, denied} ->
        if fun in denied, do: [not_allowed(mod, fun) | acc], else: acc

      {:only, allowed} ->
        if fun in allowed, do: acc, else: ["#{inspect(mod)}.#{fun} is not allowed" | acc]

      _ ->
        acc
    end
  end

  defp not_allowed(mod, fun) when mod in [Date, Time, DateTime, NaiveDateTime],
    do:
      "#{inspect(mod)}.#{fun} is not allowed: units do not read the clock, so recorded calls replay the same; take the time as an argument (an endpoint unit has request.now)"

  defp not_allowed(Enum, fun),
    do: "Enum.#{fun} is not allowed: units are deterministic, so recorded calls replay the same"

  defp not_allowed(mod, fun), do: "#{inspect(mod)}.#{fun} is not allowed"

  # Seed units are mostly data, so they may be as long as specs.
  defp length_kind(:pure, ast), do: if(Theseus.Seed.seed_unit?(ast), do: :seed, else: :pure)
  defp length_kind(kind, _ast), do: kind

  defp max_lines(kind) when kind in [:spec, :seed], do: @max_spec_lines
  defp max_lines(_kind), do: @max_lines

  defp too_long(:spec, lines),
    do:
      "#{lines} lines; specs are capped at #{@max_spec_lines}: move rules about one unit's flow into that unit's spec (they can use app), or split the unit and its spec in two"

  defp too_long(:seed, lines),
    do:
      "#{lines} lines; seed units are capped at #{@max_spec_lines}: build rows in a comprehension, or split them across two seed units"

  defp too_long(_kind, lines),
    do: "#{lines} lines; units are capped at #{@max_lines}, split it into two units"

  defp defines?(body, name, arity) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:def, _, [{:when, _, [{^name, _, args} | _]} | _]} = node, _
        when length(args) == arity ->
          {node, true}

        {:def, _, [{^name, _, args} | _]} = node, _
        when is_list(args) and length(args) == arity ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found
  end

  defp check_module(mod, ctx, acc) do
    cond do
      mod == ctx.self ->
        ["refer to the unit itself as __MODULE__, not #{inspect(mod)}" | acc]

      Map.has_key?(ctx.allowed, mod) ->
        acc

      mod in ctx.named ->
        acc

      mod in ctx.units ->
        acc

      exception?(mod) ->
        acc

      mod == Theseus.Store ->
        [
          "Theseus.Store is for endpoint and store units (use Theseus.Store); other units get the data they need passed in"
          | acc
        ]

      ctx.uses in [[Theseus.Endpoint], [Theseus.Store]] ->
        ["#{inspect(mod)} is neither allowed nor a unit on this branch" | acc]

      ctx.uses == [GenServer] ->
        [
          "#{inspect(mod)} is neither allowed nor a pure unit on this branch " <>
            "(server units call only pure units)"
          | acc
        ]

      true ->
        ["#{inspect(mod)} is not on the allowlist" | acc]
    end
  end

  defp resolve({:__aliases__, _, [{:__MODULE__, _, _}]}), do: :self
  defp resolve({:__aliases__, _, [{:__MODULE__, _, _} | _]}), do: :dynamic

  defp resolve({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:module, Module.concat(parts)}, else: :dynamic
  end

  defp resolve({:__MODULE__, _, _}), do: :self
  defp resolve(atom) when is_atom(atom), do: {:module, atom}
  defp resolve(_), do: :dynamic

  defp module?(atom), do: :code.which(atom) != :non_existing

  defp exception?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :exception, 1) and
      function_exported?(mod, :message, 1)
  end
end
