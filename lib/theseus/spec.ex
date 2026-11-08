defmodule Theseus.Spec do
  @moduledoc """
  The behavioural spec of one unit. A spec is a module, kept in the ledger
  like a unit. Agents may propose spec changes; a person approves every one.

      defmodule Sample.Pricing.Spec do
        use Theseus.Spec

        spec Sample.Pricing, deterministic: true do
          prose "Computes subtotal, discount, shipping and total in cents."

          example "no coupon",
            total: [[%{qty: 2, unit_cents: 1000}], nil],
            expect: %{subtotal_cents: 2000, discount_cents: 0, shipping_cents: 599, total_cents: 2599}

          property "total is never negative",
            total: [list_of(item_gen()), rule_gen()],
            check: fn %{total_cents: t} -> t >= 0 end
        end

        defp item_gen, do: fixed_map(%{qty: integer(1..20), unit_cents: integer(0..50_000)})
        defp rule_gen, do: constant(nil)
      end

  `use Theseus.Spec` imports the DSL and `StreamData`. The module's
  `__spec__/0` returns the `%Theseus.Spec{}`. A property's `check` takes the
  result, or the argument list and the result. An invariant's `check` takes a
  function `call.(fun, args)` that calls the unit under test, and optionally
  a second, `app.(fun, args)`, that calls the app's root endpoint unit (its
  `handle/1`, `sign_in/1`, `connection/1`, `fetched/1` or `tick/1`), so a unit's spec can
  check a flow through the whole app. In validation every example, property
  and invariant starts on fresh server state, and `app` reaches the versions
  being checked.
  """

  @type example :: %{name: String.t(), fun: atom(), args: [term()], expect: term()}
  @type property :: %{
          name: String.t(),
          fun: atom(),
          gen: StreamData.t([term()]),
          check: (term() -> boolean()) | ([term()], term() -> boolean()),
          runs: pos_integer() | nil
        }
  @type invariant :: %{
          name: String.t(),
          check:
            ((atom(), [term()] -> term()) -> boolean())
            | ((atom(), [term()] -> term()), (atom(), [term()] -> term()) -> boolean())
        }

  @type t :: %__MODULE__{
          unit: module(),
          examples: [example()],
          properties: [property()],
          invariants: [invariant()],
          equivalence: (term(), term() -> boolean()),
          deterministic: boolean(),
          prose: String.t()
        }

  @enforce_keys [:unit]
  defstruct [
    :unit,
    examples: [],
    properties: [],
    invariants: [],
    equivalence: &==/2,
    deterministic: true,
    prose: ""
  ]

  defmacro __using__(_opts) do
    quote do
      import Theseus.Spec, only: [spec: 2, spec: 3]
      import Theseus.Spec.DSL
      import StreamData
    end
  end

  @doc "Defines `__spec__/0`, which builds the spec each time it is called."
  defmacro spec(unit, opts \\ [], do: block) do
    entries =
      case block do
        {:__block__, _, exprs} -> exprs
        nil -> []
        expr -> [expr]
      end

    quote do
      def __spec__ do
        Theseus.Spec.build(unquote(unit), unquote(opts), unquote(entries))
      end
    end
  end

  @doc false
  def build(unit, opts, entries) do
    spec = %__MODULE__{unit: unit, deterministic: Keyword.get(opts, :deterministic, true)}

    spec =
      Enum.reduce(entries, spec, fn
        {:prose, text}, s -> %{s | prose: String.trim(text)}
        {:example, e}, s -> %{s | examples: s.examples ++ [e]}
        {:property, p}, s -> %{s | properties: s.properties ++ [p]}
        {:invariant, i}, s -> %{s | invariants: s.invariants ++ [i]}
        {:equivalence, f}, s -> %{s | equivalence: f}
        other, _ -> raise ArgumentError, "not a spec entry: #{inspect(other)}"
      end)

    spec
  end

  @doc """
  Runs a spec's examples, properties and invariants against `module`
  (default: the spec's own unit).

  `spec_or_unit` is a `%Theseus.Spec{}` or a registered unit. Options:
  `:runs` (property runs, default 100), `:seed` (a three-integer tuple),
  and `:before_each`, a function called before each example, property and
  invariant (validation uses it to start every rule on fresh server state).
  """
  @spec run(t() | module(), module() | nil, keyword()) :: %{
          unit: module(),
          module: module(),
          passed: boolean(),
          results: [map()]
        }
  def run(spec_or_unit, module \\ nil, opts \\ [])

  def run(%__MODULE__{} = spec, module, opts) do
    module = module || spec.unit
    seed = Keyword.get_lazy(opts, :seed, &:os.timestamp/0)
    runs = Keyword.get(opts, :runs, 100)

    before_each = Keyword.get(opts, :before_each, fn -> :ok end)

    each = fn run ->
      fn rule ->
        Theseus.Store.reset()
        before_each.()
        run.(rule)
      end
    end

    # A rule's calls to the app apply the writes they return to the store,
    # like calls to the unit (see `Theseus.Store.applying/1`).
    app_fun = Keyword.get(opts, :app, &no_app/2)
    app = fn fun, args -> Theseus.Store.applying(fn -> app_fun.(fun, args) end) end

    results =
      Enum.map(spec.examples, each.(&run_example(&1, module, spec.equivalence))) ++
        Enum.map(spec.properties, each.(&run_property(&1, module, seed, runs))) ++
        Enum.map(spec.invariants, each.(&run_invariant(&1, module, app)))

    %{
      unit: spec.unit,
      module: module,
      passed: Enum.all?(results, &(&1.result == :pass)),
      results: results
    }
  end

  def run(unit, module, opts) when is_atom(unit) do
    case Theseus.Registry.spec(unit) do
      nil -> raise ArgumentError, "no spec loaded for #{inspect(unit)}"
      spec -> run(spec, module, opts)
    end
  end

  @doc """
  The readable form of a spec, for people: the prose, examples as rows, and
  rules and invariants by name. No code.
  """
  @spec describe(t()) :: map()
  def describe(%__MODULE__{} = spec) do
    %{
      unit: inspect(spec.unit),
      prose: spec.prose,
      deterministic: spec.deterministic,
      examples: Enum.map(spec.examples, &example_row/1),
      rules: Enum.map(spec.properties, & &1.name),
      invariants: Enum.map(spec.invariants, & &1.name)
    }
  end

  @doc "What changed between two versions of a spec, in readable form."
  @spec diff(t(), t()) :: map()
  def diff(%__MODULE__{} = old, %__MODULE__{} = new, old_ast \\ nil, new_ast \\ nil) do
    old_examples = Map.new(old.examples, &{&1.name, example_row(&1)})
    new_examples = Map.new(new.examples, &{&1.name, example_row(&1)})
    changed = changed_rules(old_ast, new_ast)

    %{
      prose: if(old.prose == new.prose, do: nil, else: %{before: old.prose, after: new.prose}),
      examples_added:
        for({name, row} <- new_examples, not Map.has_key?(old_examples, name), do: row),
      examples_removed:
        for({name, row} <- old_examples, not Map.has_key?(new_examples, name), do: row),
      examples_changed: changed_examples(old_examples, new_examples),
      rules_added: names(new.properties) -- names(old.properties),
      rules_removed: names(old.properties) -- names(new.properties),
      invariants_added: names(new.invariants) -- names(old.invariants),
      invariants_removed: names(old.invariants) -- names(new.invariants),
      # Rules kept under the same sentence whose code, or the code of a
      # helper they use, changed: their meaning may have changed.
      rules_changed:
        for(
          n <- names(new.properties ++ new.invariants),
          n in names(old.properties ++ old.invariants),
          n in changed,
          do: n
        )
    }
  end

  @doc false
  # The names of the rules (properties and invariants) whose code differs
  # between two spec modules' syntax trees, counting the private helpers
  # each rule calls, directly or through other helpers.
  def changed_rules(nil, _new_ast), do: []
  def changed_rules(_old_ast, nil), do: []

  def changed_rules(old_ast, new_ast) do
    old = rule_code(old_ast)
    new = rule_code(new_ast)
    for {name, code} <- new, Map.has_key?(old, name), old[name] != code, do: name
  end

  @doc """
  Each rule's code (a property or invariant, by its sentence) with the
  private helpers it reaches, as text, from a spec module's syntax tree.
  """
  @spec rule_sources(Macro.t()) :: %{String.t() => String.t()}
  def rule_sources(ast), do: rule_code(ast)

  # Rule name => the rule's code and the helpers it reaches, as text.
  defp rule_code({:defmodule, _, [_name, [do: body]]}) do
    forms = List.wrap(unblock(body))

    helpers = group_helpers(forms)

    rules =
      for {:spec, _, [_unit | rest]} <- forms,
          [do: block] <- [List.last(rest)],
          {kind, _, [name, opts]} <- List.wrap(unblock(block)),
          kind in [:property, :invariant],
          is_binary(name),
          do: {name, opts}

    Map.new(rules, fn {name, opts} ->
      reached = reach_helpers(calls(opts), helpers, MapSet.new())
      helper_text = reached |> Enum.sort() |> Enum.map(&Macro.to_string(helpers[&1]))
      {name, Enum.join([Macro.to_string(opts) | helper_text], "\n")}
    end)
  end

  defp rule_code(_ast), do: %{}

  defp unblock({:__block__, _, forms}), do: forms
  defp unblock(form), do: form

  defp helper_name({:when, _, [head | _]}), do: helper_name(head)
  defp helper_name({name, _, _}) when is_atom(name), do: name

  # All clauses of each helper, together.
  defp group_helpers(forms) do
    forms
    |> Enum.filter(&match?({kind, _, _} when kind in [:def, :defp], &1))
    |> Enum.group_by(fn {_, _, [head | _]} -> helper_name(head) end)
    |> Map.new(fn {name, clauses} -> {name, {:__block__, [], clauses}} end)
  end

  defp calls(ast) do
    {_, found} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp reach_helpers(names, helpers, seen) do
    new = for n <- names, Map.has_key?(helpers, n), n not in seen, do: n

    Enum.reduce(new, MapSet.union(seen, MapSet.new(new)), fn n, acc ->
      reach_helpers(calls(helpers[n]), helpers, acc)
    end)
  end

  defp changed_examples(old_examples, new_examples) do
    for {name, row} <- new_examples,
        old_row = old_examples[name],
        old_row != nil and old_row != row,
        do: %{name: name, before: old_row, after: row}
  end

  defp names(entries), do: Enum.map(entries, & &1.name)

  defp example_row(example) do
    args = Enum.map_join(example.args, ", ", &inspect(&1, limit: 50))

    %{
      name: example.name,
      call: "#{example.fun}(#{args})",
      expect: inspect(example.expect, limit: 50)
    }
  end

  defp run_example(example, module, equivalence) do
    result =
      case invoke(module, example.fun, example.args) do
        {:ok, value} ->
          if holds?(fn -> equivalence.(value, example.expect) end),
            do: :pass,
            else: {:fail, %{expected: example.expect, got: value}}

        {:raised, error} ->
          {:fail, %{expected: example.expect, raised: error}}
      end

    %{kind: :example, name: example.name, result: result}
  end

  defp run_property(property, module, seed, runs) do
    options = [initial_seed: seed, max_runs: property.runs || runs]

    outcome =
      StreamData.check_all(property.gen, options, fn args ->
        Theseus.Store.reset()

        case invoke(module, property.fun, args) do
          {:ok, value} ->
            if holds?(fn -> check(property.check, args, value) end),
              do: {:ok, nil},
              else: {:error, %{args: args, got: value}}

          {:raised, error} ->
            {:error, %{args: args, raised: error}}
        end
      end)

    result =
      case outcome do
        {:ok, _} -> :pass
        {:error, info} -> {:fail, %{counterexample: info.shrunk_failure, seed: seed}}
      end

    %{kind: :property, name: property.name, result: result}
  rescue
    # A generator that cannot produce inputs fails its property, not the run.
    e ->
      %{
        kind: :property,
        name: property.name,
        result: {:fail, %{generator: Exception.message(e) |> String.slice(0, 300)}}
      }
  end

  # An invariant's check takes `call`, which calls its unit, and optionally
  # `app`, which calls the app's root endpoint unit.
  defp run_invariant(invariant, module, app) do
    call = fn fun, args -> Theseus.Store.applying(fn -> apply(module, fun, args) end) end

    run =
      if is_function(invariant.check, 2),
        do: fn -> invariant.check.(call, app) end,
        else: fn -> invariant.check.(call) end

    result =
      case outcome(run) do
        true -> :pass
        {:raised, text} -> {:fail, %{raised: text}}
        _false -> {:fail, %{}}
      end

    %{kind: :invariant, name: invariant.name, result: result}
  end

  defp no_app(_fun, _args),
    do: raise(ArgumentError, "app is only available when validation runs the spec")

  # What a check returned, or what it raised, threw or exited with, as text.
  defp outcome(fun) do
    fun.()
  catch
    kind, reason ->
      text =
        case kind do
          :error -> Exception.message(Exception.normalize(:error, reason, __STACKTRACE__))
          _ -> "#{kind} #{inspect(reason, limit: 10)}"
        end

      # Candidate modules are named for the unit they stand for.
      text = String.replace(text, ~r/Theseus\.Candidate\.[A-Za-z0-9]+\./, "")
      {:raised, String.slice(text, 0, 400)}
  end

  defp check(fun, _args, value) when is_function(fun, 1), do: fun.(value)
  defp check(fun, args, value) when is_function(fun, 2), do: fun.(args, value)

  # A check holds only if it returns true; raising, throwing or exiting
  # (a call to a stopped server, say) means it does not.
  defp holds?(fun) do
    fun.() == true
  catch
    _kind, _reason -> false
  end

  defp invoke(module, fun, args) do
    {:ok, Theseus.Store.applying(fn -> apply(module, fun, args) end)}
  catch
    :error, reason -> {:raised, Exception.normalize(:error, reason, __STACKTRACE__)}
    kind, reason -> {:raised, {kind, reason}}
  end
end

defmodule Theseus.Spec.DSL do
  @moduledoc "Entries allowed inside a `spec` block."

  def prose(text) when is_binary(text), do: {:prose, text}

  @doc ~S|`example "name", fun: [args], expect: value`|
  def example(name, opts) when is_binary(name) and is_list(opts) do
    {expect, rest} = Keyword.pop!(opts, :expect)
    {fun, args} = single_call!(name, rest)
    {:example, %{name: name, fun: fun, args: args, expect: expect}}
  end

  @doc ~S|`property "name", fun: [generators], check: fn result -> bool end`. Optional `runs:`.|
  def property(name, opts) when is_binary(name) and is_list(opts) do
    {check, rest} = Keyword.pop!(opts, :check)
    {runs, rest} = Keyword.pop(rest, :runs)
    {fun, gens} = single_call!(name, rest)

    unless is_function(check, 1) or is_function(check, 2) do
      raise ArgumentError, "property #{inspect(name)}: check must take 1 or 2 arguments"
    end

    {:property,
     %{name: name, fun: fun, gen: StreamData.fixed_list(gens), check: check, runs: runs}}
  end

  @doc ~S|`invariant "name", check: fn call -> bool end`, where `call.(fun, args)` calls the unit.|
  def invariant(name, opts) when is_binary(name) and is_list(opts) do
    {:invariant, %{name: name, check: Keyword.fetch!(opts, :check)}}
  end

  def equivalence(fun) when is_function(fun, 2), do: {:equivalence, fun}

  defp single_call!(_name, [{fun, args}]) when is_atom(fun) and is_list(args), do: {fun, args}

  defp single_call!(name, other) do
    raise ArgumentError,
          "#{inspect(name)}: expected exactly one `fun: [args]` entry, got #{inspect(other)}"
  end
end
