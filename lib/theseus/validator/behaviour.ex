defmodule Theseus.Validator.Behaviour do
  @moduledoc """
  The evidence a person reviews instead of code. Never fails a change.

    * `traces`: every retained recorded call (`Theseus.Traces.replay_set/2`)
      run through the live unit and through the candidate. Lists the calls
      whose result changes, that now succeed, and that now fail. For a crash
      fix, calls that failed with the crash's signature are `fixed` when
      they now succeed and `unfixed` when they do not. The `:replay` stage
      judges this list. A server unit's calls are replayed in the order
      they were recorded, all of them, with both systems starting from a
      copy of the live state.
    * `spec_after`: the readable spec the unit will have after the change.
    * `spec`: for a change that includes a spec, the examples and rules that
      were added or removed, and which of them the live unit does not meet.
      Those are the behaviours the change asks for.

  `classify/3` and `summary/1` are shared with `Theseus.Shadow`, so recorded
  and live comparisons read the same way.
  """

  alias Theseus.{Change, PageText, Signature, Spec, Version}
  alias Theseus.Store.Side

  @list_cap 20

  @type item :: %{
          fun: atom(),
          args: [term()],
          before: {:ok, term()} | {:error, term()},
          after: {:ok, term()} | {:error, term()},
          class: :same | :changed | :now_succeed | :now_fail | :fixed | :unfixed | :removed
        }

  # `removed`: the call is to a function the candidate no longer has. Those
  # are listed but not counted as differences: a unit that still calls the
  # function breaks, and the dependents stage catches that.
  @classes [:changed, :now_succeed, :now_fail, :fixed, :unfixed, :removed]

  @doc """
  Runs on the sandbox node. `ctx` describes the live system; see
  `Theseus.Validator`. Options: `:fresh` and `:live` put the server units
  on fresh or live state, before the proposed spec runs and before the
  replay; `:before_each` runs before each replayed call.
  """
  @spec compare(Change.t(), %{module() => module()}, map(), keyword()) :: map()
  def compare(%Change{} = change, renamed, ctx, opts \\ []) do
    base = %{spec_after: spec_after(change, renamed, ctx)}

    if Change.creates?(change) do
      Map.put(base, :created, true)
    else
      spec = with_state(opts[:fresh], fn -> spec(change, renamed, ctx, opts) end)
      traces = with_state(opts[:live], fn -> traces(change, renamed, ctx, opts) end)

      traces =
        traces && Map.put(traces, :dropped_callbacks, dropped_callbacks(change, renamed, ctx))

      Map.merge(base, %{traces: traces, spec: spec})
    end
  end

  @engine_callbacks [handle: 1, sign_in: 1, allow?: 1, connection: 1, fetched: 1, tick: 1]

  # Callbacks the engine calls on the root endpoint unit that the live root
  # has and the proposed one does not, as "tick/1".
  defp dropped_callbacks(change, renamed, ctx) do
    with true <- ctx[:root] == change.unit,
         %Version{unit: unit} <- Change.unit_candidate(change),
         candidate when candidate != nil <- renamed[unit] do
      Code.ensure_loaded(unit)
      Code.ensure_loaded(candidate)

      for {fun, arity} <- @engine_callbacks,
          function_exported?(unit, fun, arity),
          not function_exported?(candidate, fun, arity),
          do: "#{fun}/#{arity}"
    else
      _ -> []
    end
  end

  defp with_state(nil, fun), do: fun.()

  defp with_state(put_state, fun) do
    put_state.()
    fun.()
  end

  @doc """
  The class of one call, given whether its live failure is the crash being
  fixed (`target?`).
  """
  def classify_call(before, after_, equivalent, target?) do
    case {target?, after_} do
      {true, {:ok, _}} -> :fixed
      {true, _} -> :unfixed
      {false, _} -> classify(before, after_, equivalent)
    end
  end

  @doc "Whether the candidate no longer has the function a call is to."
  def removed?(candidate, fun, args) do
    Code.ensure_loaded(candidate)
    not function_exported?(candidate, fun, length(args))
  end

  @doc "Whether a live result is a failure with `signature`."
  def target?(nil, _unit, _fun, _args, _before), do: false

  def target?(signature, unit, fun, args, {:error, error}),
    do: Signature.matches?(signature, unit, fun, length(args), error)

  def target?(_signature, _unit, _fun, _args, _before), do: false

  defp target_through?(nil, _before), do: false

  defp target_through?(signature, {:error, error}),
    do: Signature.matches?(signature, signature.unit, signature.fun, signature.arity, error)

  defp target_through?(_signature, _before), do: false

  @doc """
  Sorts one comparison. Results are compared with the spec's equivalence.
  Two errors count as the same when they are the same kind of exception.
  """
  @spec classify({:ok, term()} | {:error, term()}, {:ok, term()} | {:error, term()}, fun()) ::
          :same | :changed | :now_succeed | :now_fail
  def classify({:ok, b}, {:ok, a}, equivalent),
    do: if(equivalent?(equivalent, b, a), do: :same, else: :changed)

  def classify({:error, _}, {:ok, _}, _equivalent), do: :now_succeed
  def classify({:ok, _}, {:error, _}, _equivalent), do: :now_fail

  def classify({:error, b}, {:error, a}, _equivalent),
    do: if(error_type(b) == error_type(a), do: :same, else: :changed)

  @doc """
  Counts and the first few rows of each kind of difference. `differ` counts
  everything except calls the change was meant to fix.
  """
  @spec summary([item()]) :: map()
  def summary(items) do
    by_class = Enum.group_by(items, & &1.class)
    # Pages that differ only in styling are counted, and listed after the
    # other differences.
    {styling, other} =
      Enum.split_with(by_class[:changed] || [], &PageText.styling_only?(&1.before, &1.after))

    by_class =
      if by_class[:changed], do: Map.put(by_class, :changed, other ++ styling), else: by_class

    refusals = for %{after: {:ok, result}} <- items, why <- refusals(result), do: why
    bad_htmx = for %{after: {:ok, result}} <- items, why <- htmx_refusals(result), do: why

    bad_writes =
      for(%{after: {:ok, result}} <- items, why <- write_refusals(result), do: why) ++
        for(%{after_write: {:refused, why}} <- items, do: why)

    counts =
      @classes
      |> Map.new(&{&1, length(by_class[&1] || [])})
      |> Map.put(:styling_only, length(styling))
      |> Map.put(:refused_messages, length(refusals))
      |> Map.put(:refused_htmx, length(bad_htmx))
      |> Map.put(:refused_writes, length(bad_writes))

    rows =
      Map.new(@classes, fn class ->
        {class,
         (by_class[class] || []) |> Enum.take(@list_cap) |> Enum.map(&Map.delete(&1, :class))}
      end)

    Map.merge(rows, %{
      refused_example: List.first(refusals),
      refused_htmx_example: List.first(bad_htmx),
      refused_writes_example: List.first(bad_writes),
      # Calls to a removed function are run on neither side.
      compared: length(items) - counts.removed,
      differ: counts.changed + counts.now_succeed + counts.now_fail + counts.unfixed,
      counts: counts
    })
  end

  # Why the outbox would refuse each message a result sends, if it would.
  defp refusals(result) do
    {messages, _result} = Theseus.Outbox.unwrap(result, [])
    for m <- messages, {:error, why} <- [Theseus.Outbox.normalize(m)], do: why
  end

  # Why the store would refuse the writes a result returns, if it would
  # (their shape; columns are checked against the live tables when applied).
  defp write_refusals(result) do
    case Theseus.Store.take_writes(result) do
      {[], _result} ->
        []

      {ops, _result} ->
        with({:error, why} <- Theseus.Store.check_writes(ops), do: [why], else: (_ -> []))
    end
  end

  # Why the engine would refuse the htmx headers a result sets, if it would.
  defp htmx_refusals(result) do
    case Theseus.Outbox.unwrap(result, []) do
      {_messages, {:htmx, headers, inner}} ->
        case Theseus.Web.htmx_headers(headers) do
          {:ok, _} -> htmx_refusals(inner)
          {:error, why} -> [why]
        end

      _ ->
        []
    end
  end

  @doc "Calls `module.fun(args...)` and returns `{:ok, result}` or `{:error, error}`."
  def invoke(module, fun, args) do
    {:ok, apply(module, fun, args)}
  catch
    :error, reason -> {:error, Exception.normalize(:error, reason, __STACKTRACE__)}
    kind, reason -> {:error, {kind, reason}}
  end

  defp live_spec(%{spec_module: nil}), do: nil
  defp live_spec(%{spec_module: spec_module}), do: spec_module.__spec__()

  # The readable spec the unit will have if the change is approved.
  defp spec_after(change, renamed, ctx) do
    case Change.spec_candidate(change) do
      %Version{unit: spec_module} -> Spec.describe(renamed[spec_module].__spec__())
      nil -> with(%Spec{} = s <- live_spec(ctx), do: Spec.describe(s))
    end
  end

  # "Before" is the live unit run now, not the recorded result: a recorded
  # call may come from an older version.
  defp traces(change, renamed, ctx, opts) do
    case Change.unit_candidate(change) do
      nil ->
        nil

      %Version{unit: unit} ->
        equivalent = equivalence(change, renamed, ctx)

        replay_calls(unit, renamed[unit], ctx.replay_set, equivalent, ctx.signature,
          before_each: Keyword.get(opts, :before_each, fn -> :ok end),
          snapshot: ctx[:snapshot],
          tables: ctx[:store_tables]
        )
    end
  end

  @doc """
  Runs recorded calls through the live unit and through a candidate and
  summarises the differences (see `summary/1`). `signature` is the crash a
  fix is meant to fix, or nil. With `through: true` the unit is a caller of
  the crashing unit, and a call that failed with the crash as it passed
  through counts as one the fix is meant to fix.
  """
  @spec replay_calls(module(), module(), [map()], fun(), term(), keyword()) :: map()
  def replay_calls(unit, candidate, replay_set, equivalent, signature, opts \\ []) do
    before_each = Keyword.get(opts, :before_each, fn -> :ok end)
    side_opts = Keyword.take(opts, [:snapshot, :tables])

    # A call to a function the live unit does not have was recorded on
    # another version (one since rolled back, say); it cannot be compared.
    calls = Enum.reject(replay_set, fn %{fun: fun, args: args} -> removed?(unit, fun, args) end)

    # Each side runs every call on its own data, one side after the other:
    # two open transactions writing the same rows would wait on each other
    # (see `Theseus.Store.Side`).
    {befores, data} = on_side(side_opts, calls, before_each, candidate, &invoke(unit, &1, &2))
    {afters, _} = on_side(side_opts, calls, before_each, candidate, &invoke(candidate, &1, &2))

    Enum.zip_with([calls, befores, afters], fn
      [%{fun: fun, args: args} = trace, :removed, :removed] ->
        # Run on neither side: a call only one side could take would change
        # that side's state alone, and every later comparison with it. The
        # row shows what was recorded.
        %{
          fun: fun,
          args: args,
          before: recorded(trace),
          after: {:error, :removed},
          class: :removed
        }

      [%{fun: fun, args: args}, {before, _}, {after_, after_write}] ->
        target? =
          if opts[:through],
            do: target_through?(signature, before),
            else: target?(signature, unit, fun, args, before)

        %{
          fun: fun,
          args: args,
          before: before,
          after: after_,
          after_write: after_write,
          class: classify_call(before, after_, equivalent, target?)
        }
    end)
    |> summary()
    |> Map.put(:data, data)
  end

  defp on_side(side_opts, calls, before_each, candidate, run) do
    {side, data} = Side.start(side_opts)

    try do
      results =
        for %{fun: fun, args: args} <- calls do
          before_each.()

          if removed?(candidate, fun, args),
            do: :removed,
            else: Side.run(side, fn -> run.(fun, args) end)
        end

      {results, data}
    after
      Side.stop(side)
    end
  end

  defp recorded(%{result: {:ok, value}}), do: {:ok, value}
  defp recorded(%{result: {:error, error, _stacktrace}}), do: {:error, error}
  defp recorded(_trace), do: {:error, :not_run}

  # The proposed spec against the live system: the live unit, and `app`
  # reaching the live root endpoint.
  defp spec(change, renamed, ctx, opts) do
    with %Version{unit: spec_module} <- Change.spec_candidate(change),
         live when live != nil <- live_spec(ctx) do
      proposed = renamed[spec_module].__spec__()
      diff = Spec.diff(live, proposed, ctx[:spec_ast], Change.spec_candidate(change).ast)

      run_opts =
        [runs: 50, before_each: opts[:fresh] || fn -> :ok end] ++
          if(opts[:live_app], do: [app: opts[:live_app]], else: [])

      run = Spec.run(proposed, change.unit, run_opts)
      live_misses = for %{result: {:fail, _}} = r <- run.results, do: r.name
      Map.put(diff, :live_unit_misses, live_misses)
    else
      _ -> nil
    end
  end

  defp equivalence(change, renamed, ctx) do
    case Change.spec_candidate(change) do
      %Version{unit: spec_module} -> renamed[spec_module].__spec__().equivalence
      nil -> (live_spec(ctx) || %Spec{unit: change.unit}).equivalence
    end
  end

  defp equivalent?(fun, a, b) do
    fun.(a, b) == true
  rescue
    _ -> false
  end

  defp error_type(%{__exception__: true, __struct__: type}), do: type
  # Exits and throws compare by what kind they are, not their whole term,
  # which names candidate modules on one side and live ones on the other.
  defp error_type({kind, reason}) when kind in [:exit, :throw], do: {kind, reason_kind(reason)}
  defp error_type(other), do: other

  defp reason_kind(reason) when is_atom(reason), do: reason
  defp reason_kind({%{__exception__: true, __struct__: type}, _}), do: type
  defp reason_kind({{inner, _}, _}) when is_atom(inner), do: inner
  defp reason_kind({inner, _}) when is_atom(inner), do: inner
  defp reason_kind(_reason), do: :other
end
