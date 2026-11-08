defmodule Theseus.Store do
  @moduledoc """
  The app's data, in Postgres (design: `docs/database-design.md`). Tables
  are declared in schema units (`Theseus.Schema`).

  Endpoint units read with `get/2`, `all/2` and `count/2`, whose queries
  are data, and return their writes as data around their result:

      {:write, [{:insert, :activity, %{id: id, domain: d, ...}}], {:redirect, "/"}}

  Writes are `{:insert, table, row}`, `{:update, table, id, changes}` and
  `{:delete, table, id}`; an update or delete may end with `if: where` to
  apply only while the row still matches. The wrapper sits inside or
  outside `{:send, ...}` and `{:htmx, ...}`.

  The engine runs each request, tick, sync and sign-in that may use the
  store (`run/3`) in one REPEATABLE READ transaction: the unit's reads,
  then its writes, then the commit; messages are queued after the commit.
  A write whose row changed meanwhile, or a serialization failure, rolls
  everything back and runs the unit again, at most three times, unless it
  called a server unit, whose state cannot be rolled back.

  Rows are maps with atom keys. Every read is ordered: by `order`, then by
  `id`, with text compared by bytes. On the sandbox, where validation runs,
  the store is in memory: empty, or the rows a spec gives `with_rows/2`.
  """

  require Logger

  alias Theseus.Store.DB

  @doc """
  Makes a store unit: a unit that keeps a table's reads and writes for the
  endpoint units, with their rules (it reads with get/2, all/2, count/2
  and aggregate/2, returns writes as data, calls other units through
  `Theseus.call/3`) and no routes. Endpoint units call it with
  `Theseus.call/3`; it is replayed, and shadowed like an endpoint unit.

      defmodule App.Requests do
        use Theseus.Store

        def pending(domain),
          do: Theseus.Store.all(:requests, where: [domain: domain, status: "pending"])

        def decide(id, status),
          do: {:write, [{:update, :requests, id, %{status: status}, if: [status: "pending"]}], :ok}
      end
  """
  defmacro __using__(_opts), do: nil

  @ctx {__MODULE__, :ctx}
  @touched {__MODULE__, :server_touched}
  @call {__MODULE__, :call}
  @attempts 3
  @default_limit 1_000
  @max_limit 100_000
  @ops [:<, :<=, :>, :>=, :!=, :in]

  ## Reads, for endpoint units

  @doc "The row with this id, or nil. Nothing but text names a row, so any other id finds nothing."
  @spec get(atom(), term()) :: map() | nil
  def get(table, id) when is_atom(table) and is_binary(id) do
    case all(table, where: [id: id], limit: 1) do
      [row] -> row
      [] -> nil
    end
  end

  def get(table, _id) when is_atom(table), do: nil

  @doc """
  Rows of a table. Options:

    * `where`: a keyword list of column: value, nil, `{:not, nil}`,
      `{:in, values}`, `{op, value}` with op one of `:<`, `:<=`, `:>`,
      `:>=`, `:!=`, or for text `{:contains, text}` or `{:icontains, text}`
      (which ignores the case of ASCII letters only). All must hold.
    * `join`: `[name: {:table, :column}]`. Each row gets `name`, the row of
      `table` whose id is the row's `column`, or nil. `where` and `order`
      reach its columns as `name: [column: condition]` and
      `asc: {name, column}`.
    * `order`: `[asc: column, desc: column]`, then by id.
    * `limit` (default 1,000) and `offset`.
  """
  @spec all(atom(), keyword()) :: [map()]
  def all(table, opts \\ []) do
    query = query!(table, opts)

    case context() do
      {:memory, rows} -> memory_all(rows, query)
      {:pg, conn, tables} -> DB.all(conn, tables, query)
    end
  end

  @doc "How many rows of a table match `where`, which may use `join` (see all/2)."
  @spec count(atom(), keyword()) :: non_neg_integer()
  def count(table, opts \\ []) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:where, :join] == [],
      do: raise(ArgumentError, "count/2 takes where: and join:")

    query = query!(table, opts)

    case context() do
      {:memory, rows} -> rows |> joined(query) |> Enum.count(&matches?(&1, query.where))
      {:pg, conn, tables} -> DB.count(conn, tables, query)
    end
  end

  @doc """
  Figures over a table's rows, per group: `by` (columns; without it, one
  group of every matching row) and `compute`, a keyword list of name:
  `:count` (rows), `{:count, column}` (rows where it is set),
  `{:sum, column}` (an integer column; 0 when nothing is set),
  `{:min, column}` or `{:max, column}` (integer, text or time; nil when
  nothing is set). Also `where`, `order` (by the `by` columns or the
  computed names, then by the `by` columns) and `limit`.

      Theseus.Store.aggregate(:requests,
        by: [:status],
        compute: [n: :count, oldest: {:min, :requested_at}],
        where: [domain: d]
      )
      #=> [%{status: "approved", n: 4, oldest: ~U[...]}, %{status: "pending", n: 2, oldest: ~U[...]}]

  Without `by`, one map, even when no row matches.
  """
  @spec aggregate(atom(), keyword()) :: [map()] | map()
  def aggregate(table, opts) do
    query = aggregate_query!(table, opts)

    groups =
      case context() do
        {:memory, rows} -> memory_aggregate(rows, query)
        {:pg, conn, tables} -> DB.aggregate(conn, tables, query)
      end

    if query.by == [], do: hd(groups), else: groups
  end

  @doc """
  A new row id, the n-th for this request (or tick, sync or sign-in):
  derived from its `id`, so a replayed call creates the same ids. Without
  an `id` (a spec's request, or one recorded before ids), or for a sign-in
  identity, whose `id` names the person, from the whole of `source` and
  the call's place in the run, so two identical calls get different ids,
  the same ones on both sides of a comparison.
  """
  @spec id(map(), pos_integer()) :: String.t()
  def id(source, n \\ 1) when is_map(source) and is_integer(n) and n > 0 do
    seed =
      case source do
        # A sign-in identity's id names the person, not the sign-in.
        %{id: id} = s when is_binary(id) and not is_map_key(s, :provider) -> id
        _ -> :erlang.term_to_binary({source, Process.get(@call, 0)}, [:deterministic])
      end

    :crypto.hash(:sha256, [seed, <<n::32>>])
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, 20)
  end

  @doc """
  Runs `fun` with an in-memory store holding these rows, `%{table => [row]}`,
  for specs and tests. Reads see them; writes are returned, never applied.
  """
  @spec with_rows(map(), (-> result)) :: result when result: term()
  def with_rows(rows, fun) when is_map(rows) and is_function(fun, 0) do
    rows =
      Map.new(rows, fn {table, list} ->
        {table, Enum.map(list, fn row -> Map.new(row, fn {k, v} -> {k, value(v)} end) end)}
      end)

    previous = Process.put(@ctx, {:memory, rows})

    try do
      fun.()
    after
      restore(previous)
    end
  end

  defp context do
    case Process.get(@ctx) do
      nil ->
        if sandbox?() do
          # Specs and validation run on the sandbox: an empty store, kept
          # in this process so writes a call returns can be applied to it.
          Process.put(@ctx, {:memory, %{}})
          {:memory, %{}}
        else
          raise ArgumentError,
                "Theseus.Store is only available while the engine runs a request, tick, sync or sign-in"
        end

      :none ->
        raise ArgumentError,
              "the app has no tables yet: add a schema unit (see Theseus.Schema), and set THESEUS_DATABASE_URL"

      ctx ->
        ctx
    end
  end

  defp restore(nil), do: Process.delete(@ctx)
  defp restore(previous), do: Process.put(@ctx, previous)

  defp sandbox?, do: :persistent_term.get({Theseus.Call, :sandbox}, false)

  @doc false
  # The tables the sandbox validates writes against (nil: unknown).
  def sandbox_tables, do: :persistent_term.get({__MODULE__, :tables}, nil)

  @doc false
  def put_context(ctx), do: Process.put(@ctx, ctx)

  @doc false
  # For a shadow of an endpoint unit (`Theseus.Shadow`), in the live call's
  # process: what the call read from, and its place in the request, so the
  # candidate reads the same rows and makes the same ids. In a Postgres
  # transaction this exports its snapshot, which holds the call's reads and
  # none of its writes: `{:snapshot, id, tables, call}`. `:unavailable`
  # when it cannot.
  def shadow_source do
    call = Process.get(@call, 0)

    case Process.get(@ctx) do
      {:pg, conn, tables} ->
        case Postgrex.query(conn, "SELECT pg_export_snapshot()", []) do
          {:ok, %{rows: [[id]]}} -> {:snapshot, id, tables, call}
          _ -> :unavailable
        end

      {:memory, rows} ->
        {{:memory, rows}, call}

      _none ->
        {:none, call}
    end
  end

  @doc false
  # In a shadow's worker: the live call's store and place in the request.
  def enter_shadow(context, call) do
    Process.put(@ctx, context)
    Process.put(@call, call)
    :ok
  end

  @doc false
  # Before each spec rule on the sandbox: an empty store again.
  def reset do
    if sandbox?(), do: Process.put(@ctx, {:memory, %{}})
    Process.delete(@call)
    :ok
  end

  @doc false
  # Counts the calls into the app's code in this process (see id/2).
  def next_call, do: Process.put(@call, Process.get(@call, 0) + 1)

  @doc false
  # Runs a spec's call to the unit and applies the writes it returns to the
  # in-memory store, so the rule's next call sees them, as a later request
  # would. Elsewhere (the live node) the result is returned as it is.
  def applying(fun) do
    next_call()
    result = fun.()

    with {:memory, rows} <- Process.get(@ctx) || (sandbox?() && {:memory, %{}}),
         {[_ | _] = ops, _} <- take_writes(result) do
      case memory_apply(rows, sandbox_tables(), ops, :strict) do
        {:ok, rows} -> Process.put(@ctx, {:memory, rows})
        {:conflict, why} -> raise ArgumentError, "a write could not be applied: #{why}"
      end
    end

    result
  end

  @doc false
  # Applies writes to in-memory rows (`%{table => [row]}`). `tables` checks
  # the columns when known. In `:replay` mode an insert replaces a row with
  # the same id, as recorded calls already happened once. Raises
  # ArgumentError for a write the tables refuse.
  def memory_apply(rows, tables, ops, mode) do
    Enum.reduce_while(ops, {:ok, rows}, fn op, {:ok, rows} ->
      case write!(op) do
        {:error, why} ->
          raise ArgumentError, why

        {:insert, table, id, row, _} ->
          row = DB.complete_row!(tables, table, row)
          list = Map.get(rows, table, [])

          if mode == :strict and Enum.any?(list, &(&1.id == id)),
            do: raise(ArgumentError, "#{table} already has a row with id #{inspect(id)}"),
            else: {:cont, {:ok, Map.put(rows, table, Enum.reject(list, &(&1.id == id)) ++ [row])}}

        {:update, table, id, changes, where} ->
          changes = DB.check_row!(tables, table, changes)
          list = Map.get(rows, table, [])

          case Enum.find(list, &(&1.id == id and matches?(&1, where))) do
            nil ->
              {:halt, {:conflict, "#{table} #{id} changed or is gone"}}

            _row ->
              updated = Enum.map(list, &if(&1.id == id, do: Map.merge(&1, changes), else: &1))
              {:cont, {:ok, Map.put(rows, table, updated)}}
          end

        {:delete, table, id, _, where} ->
          list = Map.get(rows, table, [])

          if Enum.any?(list, &(&1.id == id and matches?(&1, where))),
            do: {:cont, {:ok, Map.put(rows, table, Enum.reject(list, &(&1.id == id)))}},
            else: {:halt, {:conflict, "#{table} #{id} changed or is gone"}}
      end
    end)
  end

  ## Queries

  @doc false
  def query!(table, opts) do
    unless is_atom(table) and table not in [nil, true, false],
      do: raise(ArgumentError, "a table is named with an atom, such as :activity")

    unless Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:where, :join, :search, :order, :limit, :offset] == [],
           do:
             raise(
               ArgumentError,
               "a query takes where:, join:, search:, order:, limit: and offset:"
             )

    joins = join!(Keyword.get(opts, :join, []))
    names = Keyword.keys(joins)

    %{
      table: table,
      joins: joins,
      search: search!(Keyword.get(opts, :search), names),
      where: where!(Keyword.get(opts, :where, []), names),
      order: order!(Keyword.get(opts, :order, []), names),
      limit: limit!(Keyword.get(opts, :limit, @default_limit)),
      offset: offset!(Keyword.get(opts, :offset, 0))
    }
  end

  # A join starts from a column of the table, or of an earlier join:
  # `[app: {:apps, :app_id}, team: {:teams, {:app, :team_id}}]`.
  defp join!(joins) do
    unless Keyword.keyword?(joins) and
             Enum.all?(joins, fn
               {_, {t, c}} when is_atom(t) and is_atom(c) -> true
               {_, {t, {j, c}}} when is_atom(t) and is_atom(j) and is_atom(c) -> true
               _ -> false
             end),
           do:
             raise(
               ArgumentError,
               "join: is a keyword list of name: {:table, :column} or {:table, {earlier_join, :column}}"
             )

    if length(Enum.uniq(Keyword.keys(joins))) != length(joins),
      do: raise(ArgumentError, "join: names each join once")

    Enum.reduce(joins, [], fn {name, {_t, from}}, earlier ->
      with {j, _c} <- from,
           false <- j in earlier,
           do:
             raise(
               ArgumentError,
               "join: #{inspect(j)} must be joined before a join starts from it"
             )

      earlier ++ [name]
    end)

    joins
  end

  # `search: {column_or_columns, "words"}`: every word appears in one of
  # the columns, ignoring the case of ASCII letters.
  defp search!(nil, _joins), do: nil

  defp search!({columns, text}, joins) when is_binary(text) do
    columns = List.wrap(columns)

    unless columns != [] and
             Enum.all?(columns, fn
               c when is_atom(c) -> true
               {j, c} when is_atom(c) -> j in joins
               _ -> false
             end),
           do: raise(ArgumentError, "search: names columns, or {join, column}")

    case text |> String.downcase(:ascii) |> String.split() |> Enum.uniq() do
      [] -> nil
      words -> %{columns: columns, words: words}
    end
  end

  defp search!(other, _joins),
    do:
      raise(
        ArgumentError,
        "search: is {column, \"words\"} or {[columns], \"words\"}, not #{inspect(other, limit: 3)}"
      )

  @computed [:count, :sum, :min, :max]

  defp aggregate_query!(table, opts) do
    unless is_atom(table) and table not in [nil, true, false],
      do: raise(ArgumentError, "a table is named with an atom, such as :activity")

    unless Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:by, :compute, :join, :where, :order, :limit] == [],
           do:
             raise(
               ArgumentError,
               "aggregate/2 takes by:, compute:, join:, where:, order: and limit:"
             )

    joins = join!(Keyword.get(opts, :join, []))
    names = Keyword.keys(joins)
    compute = Keyword.get(opts, :compute, [])
    path? = fn p -> is_atom(p) or match?({j, c} when is_atom(c) and is_atom(j), p) end

    # by: [:status, team: {:app, :team_id}]: a column is grouped under its
    # own name, a joined column under the name given.
    by =
      case Keyword.get(opts, :by, []) do
        list when is_list(list) ->
          Enum.map(list, fn
            c when is_atom(c) ->
              {c, c}

            {name, {j, c} = p} when is_atom(name) and is_atom(j) and is_atom(c) ->
              if j in names,
                do: {name, p},
                else: raise(ArgumentError, "by: #{inspect(j)} is not a join of this query")

            _ ->
              raise ArgumentError, "by: lists columns, and name: {join, column} for joined ones"
          end)

        _ ->
          raise ArgumentError, "by: is a list of columns"
      end

    unless Keyword.keyword?(compute) and compute != [] and
             Enum.all?(compute, fn
               {_, :count} -> true
               {_, {f, c}} -> f in @computed and path?.(c)
               _ -> false
             end),
           do:
             raise(
               ArgumentError,
               "compute: is a keyword list of name: :count, {:count, column}, {:sum, column}, {:min, column} or {:max, column}"
             )

    clash = Enum.filter(Keyword.keys(compute), &(&1 in Keyword.keys(by)))

    if clash != [] or length(Enum.uniq(Keyword.keys(compute))) != length(compute),
      do: raise(ArgumentError, "compute: names each figure once, apart from the by: columns")

    order = order!(Keyword.get(opts, :order, []), [])
    known = Keyword.keys(by) ++ Keyword.keys(compute)

    for {_dir, name} <- order,
        name not in known,
        do:
          raise(
            ArgumentError,
            "order: names a by: column or a computed name, not #{inspect(name)}"
          )

    %{
      table: table,
      joins: joins,
      by: by,
      compute: compute,
      where: where!(Keyword.get(opts, :where, []), names),
      order: order ++ for({name, _} <- by, do: {:asc, name}),
      limit: limit!(Keyword.get(opts, :limit, @default_limit))
    }
  end

  @doc false
  # Conditions, `[{column | {join, column}, condition}]`. A join's
  # conditions are a keyword list under its name.
  def where!(where, joins \\ []) do
    unless Keyword.keyword?(where),
      do: raise(ArgumentError, "where: is a keyword list of column: condition")

    Enum.flat_map(where, fn {column, condition} ->
      if column in joins do
        unless Keyword.keyword?(condition) and condition != [],
          do: raise(ArgumentError, "where: #{column}: takes a keyword list of its columns")

        for {c, cond} <- condition, do: {{column, c}, condition!(c, cond)}
      else
        [{column, condition!(column, condition)}]
      end
    end)
  end

  defp condition!(_column, nil), do: nil

  defp condition!(column, {op, text}) when op in [:contains, :icontains] do
    if is_binary(text),
      do: {op, text},
      else: raise(ArgumentError, "#{column}: #{op} takes text, not #{inspect(text, limit: 3)}")
  end

  defp condition!(_column, {:not, nil}), do: {:not, nil}

  defp condition!(column, {:in, values}) when is_list(values),
    do: {:in, Enum.map(values, &scalar!(column, &1))}

  defp condition!(column, {op, value}) when op in @ops, do: {op, scalar!(column, value)}
  defp condition!(column, value), do: scalar!(column, value)

  defp scalar!(column, value) do
    if is_binary(value) or is_integer(value) or is_boolean(value) or match?(%DateTime{}, value),
      do: value(value),
      else:
        raise(
          ArgumentError,
          "#{column}: compares with text, an integer, a boolean or a DateTime, not #{inspect(value, limit: 3)}"
        )
  end

  defp order!(column, joins) when is_atom(column), do: order!([column], joins)

  defp order!(order, joins) when is_list(order) do
    Enum.map(order, fn
      {dir, column} when dir in [:asc, :desc] and is_atom(column) ->
        {dir, column}

      {dir, {join, column}} when dir in [:asc, :desc] and is_atom(column) ->
        if join in joins,
          do: {dir, {join, column}},
          else: raise(ArgumentError, "order: #{inspect(join)} is not a join of this query")

      column when is_atom(column) ->
        {:asc, column}

      other ->
        raise ArgumentError, "order: takes asc: column or desc: column, not #{inspect(other)}"
    end)
  end

  defp order!(other, _joins),
    do: raise(ArgumentError, "order: takes asc: column or desc: column, not #{inspect(other)}")

  defp limit!(n) when is_integer(n) and n > 0 and n <= @max_limit, do: n
  defp limit!(n), do: raise(ArgumentError, "limit: is from 1 to #{@max_limit}, not #{inspect(n)}")

  defp offset!(n) when is_integer(n) and n >= 0, do: n
  defp offset!(n), do: raise(ArgumentError, "offset: is 0 or more, not #{inspect(n)}")

  @doc false
  # Values as Postgres gives them back: times to the microsecond, maps as
  # JSON with string keys.
  def value(%DateTime{} = t) do
    t = DateTime.shift_zone!(t, "Etc/UTC")
    {us, _} = t.microsecond
    %{t | microsecond: {us, 6}}
  end

  def value(map) when is_map(map) and not is_struct(map),
    do: map |> JSON.encode!() |> JSON.decode!()

  def value(other), do: other

  ## The in-memory store

  defp memory_all(rows, %{where: where, order: order} = q) do
    rows
    |> joined(q)
    |> Enum.filter(&matches?(&1, where))
    |> searched(q.search)
    |> Enum.sort(fn {ra, a}, {rb, b} ->
      if ra == rb, do: before?(a, b, order ++ [asc: :id]), else: ra > rb
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.drop(q.offset)
    |> Enum.take(q.limit)
  end

  # Each matching row with its rank: how often the words appear in the
  # columns, counting as Postgres does (lowercased ASCII, without overlaps).
  defp searched(rows, nil), do: Enum.map(rows, &{0, &1})

  defp searched(rows, %{columns: columns, words: words}) do
    for row <- rows,
        texts = for(c <- columns, t = at(row, c), is_binary(t), do: String.downcase(t, :ascii)),
        Enum.all?(words, fn w -> Enum.any?(texts, &String.contains?(&1, w)) end),
        do: {Enum.sum(for t <- texts, w <- words, do: length(:binary.matches(t, w))), row}
  end

  # The table's rows, each with its joined rows under their names.
  defp joined(rows, %{table: table, joins: joins}) do
    tables = memory_tables()
    columns!(tables, table)

    lookups =
      for {name, {other, column}} <- joins do
        base = columns!(tables, table)

        cond do
          base == nil or not is_atom(column) ->
            :ok

          Map.has_key?(base, name) ->
            raise ArgumentError, "join: #{name} is already a column of #{table}"

          not match?(%{type: :text}, base[column]) ->
            raise ArgumentError,
                  "join: #{table}.#{column} is not a text column, so it names no row"

          true ->
            columns!(tables, other)
        end

        {name, column, Map.new(Map.get(rows, other, []), &{&1.id, &1})}
      end

    for row <- Map.get(rows, table, []) do
      Enum.reduce(lookups, row, fn {name, column, by_id}, row ->
        Map.put(row, name, Map.get(by_id, at(row, column)))
      end)
    end
  end

  # The tables known on this node, to check names as Postgres would. Nil
  # in a spec without them: any name goes.
  defp memory_tables, do: :persistent_term.get({__MODULE__, :tables}, nil)

  defp columns!(nil, _table), do: nil

  defp columns!(tables, table) do
    case tables[table] do
      %{columns: columns} -> columns
      nil -> raise ArgumentError, "there is no table #{inspect(table)} in the app's schema units"
    end
  end

  defp memory_aggregate(rows, %{table: table, by: by, compute: compute} = q) do
    columns = columns!(memory_tables(), table)

    for c <- Keyword.values(by) ++ for({_, {_, c}} <- compute, do: c),
        is_atom(c),
        columns != nil and not Map.has_key?(columns, c),
        do: raise(ArgumentError, "table #{table} has no column #{inspect(c)}")

    own = for {_, {_, c}} = figure <- compute, is_atom(c), do: figure
    if columns, do: DB.check_figures!(columns, table, own)

    groups =
      rows
      |> joined(q)
      |> Enum.filter(&matches?(&1, q.where))
      |> Enum.group_by(fn row -> Map.new(by, fn {name, path} -> {name, at(row, path)} end) end)

    groups = if by == [] and groups == %{}, do: %{%{} => []}, else: groups

    groups
    |> Enum.map(fn {key, members} ->
      Enum.reduce(compute, key, fn {name, f}, acc -> Map.put(acc, name, figure(f, members)) end)
    end)
    |> Enum.sort(fn a, b -> before?(a, b, q.order) end)
    |> Enum.take(q.limit)
  end

  defp figure(:count, rows), do: length(rows)
  defp figure({:count, c}, rows), do: Enum.count(rows, &(at(&1, c) != nil))

  defp figure({:sum, c}, rows),
    do: rows |> Enum.map(&at(&1, c)) |> Enum.reject(&is_nil/1) |> Enum.sum()

  defp figure({f, c}, rows) do
    case rows |> Enum.map(&at(&1, c)) |> Enum.reject(&is_nil/1) do
      [] ->
        nil

      values ->
        Enum.reduce(values, fn v, best ->
          if compare(v, best) == :lt == (f == :min), do: v, else: best
        end)
    end
  end

  @doc false
  def matches?(row, where), do: Enum.all?(where, fn {col, c} -> holds?(at(row, col), c) end)

  # A column of the row, or of a row joined to it (nil when none is).
  defp at(row, {join, column}), do: Map.get(Map.get(row, join) || %{}, column)
  defp at(row, column), do: Map.get(row, column)

  # As SQL: a comparison with NULL is never true.
  defp holds?(value, nil), do: value == nil
  defp holds?(value, {:not, nil}), do: value != nil
  defp holds?(nil, _condition), do: false

  defp holds?(value, {:contains, text}) when is_binary(value), do: String.contains?(value, text)

  defp holds?(value, {:icontains, text}) when is_binary(value),
    do: String.contains?(ascii_down(value), ascii_down(text))

  defp holds?(_value, {op, _}) when op in [:contains, :icontains],
    do: raise(ArgumentError, "#{op} compares text only")

  defp holds?(value, {:in, values}), do: Enum.any?(values, &(compare(value, &1) == :eq))
  defp holds?(value, {:!=, v}), do: compare(value, v) != :eq
  defp holds?(value, {:<, v}), do: compare(value, v) == :lt
  defp holds?(value, {:<=, v}), do: compare(value, v) != :gt
  defp holds?(value, {:>, v}), do: compare(value, v) == :gt
  defp holds?(value, {:>=, v}), do: compare(value, v) != :lt
  defp holds?(value, v), do: compare(value, v) == :eq

  defp compare(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare(a, b) when a < b, do: :lt
  defp compare(a, b) when a > b, do: :gt
  defp compare(_a, _b), do: :eq

  # As Postgres lowers text under the "C" collation: ASCII letters only.
  defp ascii_down(text), do: String.downcase(text, :ascii)

  # Postgres puts NULLs last going up and first going down.
  defp before?(_a, _b, []), do: true

  defp before?(a, b, [{dir, col} | rest]) do
    case {at(a, col), at(b, col)} do
      {same, same} ->
        before?(a, b, rest)

      {nil, _} ->
        dir == :desc

      {_, nil} ->
        dir == :asc

      {x, y} ->
        if compare(x, y) == :eq,
          do: before?(a, b, rest),
          else: compare(x, y) == :lt == (dir == :asc)
    end
  end

  ## Writes

  @doc """
  The writes around a result and the result without them, through every
  layer of `{:write, ...}`, `{:send, ...}`, `{:fetch, ...}` and `{:htmx, ...}`.
  """
  @spec take_writes(term()) :: {[tuple()], term()}
  def take_writes({:write, ops, inner}) when is_list(ops) do
    {more, inner} = take_writes(inner)
    {ops ++ more, inner}
  end

  def take_writes({wrapper, extra, inner}) when wrapper in [:send, :htmx, :fetch] do
    {ops, inner} = take_writes(inner)
    {ops, {wrapper, extra, inner}}
  end

  def take_writes(result), do: {[], result}

  @doc "Why a list of writes is not valid, without the schema, or :ok."
  @spec check_writes([term()]) :: :ok | {:error, String.t()}
  def check_writes(ops) do
    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case write!(op) do
        {:error, why} -> {:halt, {:error, why}}
        _ -> {:cont, :ok}
      end
    end)
  end

  @doc false
  # A write as {kind, table, id, values, where}, or {:error, why}.
  def write!({:insert, table, %{id: id} = row}) when is_atom(table) and is_binary(id),
    do: {:insert, table, id, row, []}

  def write!({:insert, _table, _row}),
    do: {:error, "an insert is {:insert, table, row}, with the row's id as text in id:"}

  def write!({:update, table, id, changes}), do: write!({:update, table, id, changes, if: []})

  def write!({:update, table, id, changes, [if: where]})
      when is_atom(table) and is_binary(id) and is_map(changes) and map_size(changes) > 0 do
    if Map.has_key?(changes, :id),
      do: {:error, "an update cannot change a row's id"},
      else: guarded(:update, table, id, changes, where)
  end

  def write!({:delete, table, id}), do: write!({:delete, table, id, if: []})

  def write!({:delete, table, id, [if: where]}) when is_atom(table) and is_binary(id),
    do: guarded(:delete, table, id, %{}, where)

  def write!(other),
    do:
      {:error,
       "#{inspect(other, limit: 4)} is not a write: {:insert, table, row}, {:update, table, id, changes} or {:delete, table, id}"}

  defp guarded(kind, table, id, values, where) do
    {kind, table, id, values, where!(where)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  ## Running the app's code in a transaction

  @doc """
  Runs `fun`, an engine call into the app's code (`source` names it), in a
  transaction when the app has tables, applying the writes in its result
  and returning the result without them. When the writes cannot be applied
  after the retries, returns `conflict`.
  """
  @spec run(String.t(), (-> term()), term()) :: term()
  def run(source, fun, conflict \\ :conflict) do
    case DB.tables() do
      nil -> without_tables(source, fun)
      {:unavailable, why} -> raise ArgumentError, "the app's database cannot be reached: #{why}"
      tables -> attempt(source, fun, conflict, tables, 1)
    end
  end

  defp without_tables(source, fun) do
    previous = Process.put(@ctx, :none)

    try do
      case take_writes(fun.()) do
        {[], result} ->
          result

        {_ops, _result} ->
          raise ArgumentError,
                "#{source} returned writes, but the app has no tables: add a schema unit and set THESEUS_DATABASE_URL"
      end
    after
      restore(previous)
    end
  end

  defp attempt(source, fun, conflict, tables, n) do
    Process.delete(@touched)
    next_call()

    outcome =
      if DB.memory?(),
        do: memory_transaction(fun, tables),
        else: pg_transaction(fun, tables)

    case outcome do
      {:ok, result} ->
        result

      {:error, {:preview, result}} ->
        result

      {:error, {:conflict, why}} ->
        again(source, fun, conflict, tables, n, why)

      {:error, :serialization_failure} ->
        again(source, fun, conflict, tables, n, "another request changed the same data")
    end
  end

  # Without a database (a preview with made-up data): the rows as they are
  # now, the writes applied to them, kept unless another request wrote
  # first.
  defp memory_transaction(fun, tables) do
    {version, rows} = DB.memory_rows()
    previous = Process.put(@ctx, {:memory, rows})

    try do
      {ops, result} = take_writes(fun.())

      with {:ok, rows} <- memory_apply(rows, tables, ops, :strict),
           :ok <- if(ops == [], do: :ok, else: DB.memory_commit(version, rows)) do
        {:ok, result}
      else
        {:conflict, why} -> {:error, {:conflict, why}}
        :stale -> {:error, :serialization_failure}
      end
    after
      restore(previous)
    end
  end

  defp pg_transaction(fun, tables) do
    DB.transaction(fn conn ->
      if DB.preview?(), do: DB.preview_schema(conn)
      previous = Process.put(@ctx, {:pg, conn, tables})

      try do
        {ops, result} = take_writes(fun.())

        case DB.apply_writes(conn, tables, ops) do
          :ok -> if DB.preview?(), do: DB.rollback(conn, {:preview, result}), else: result
          {:conflict, why} -> DB.rollback(conn, {:conflict, why})
        end
      after
        if DB.preview?(), do: DB.end_overlay()
        restore(previous)
      end
    end)
  end

  defp again(source, fun, conflict, tables, n, why) do
    cond do
      Process.get(@touched) == true ->
        Logger.warning(
          "#{source}: not saved, and not retried after calling a server unit: #{why}"
        )

        conflict

      n < @attempts ->
        attempt(
          source,
          fun,
          conflict,
          with(%{} = t <- DB.tables(), do: t, else: (_ -> tables)),
          n + 1
        )

      true ->
        Logger.warning("#{source}: not saved after #{@attempts} attempts: #{why}")
        conflict
    end
  end

  @doc false
  # From Theseus.Call: the code running in a store transaction called a
  # server unit, so running it again would repeat that call's effects.
  def server_called do
    if Process.get(@ctx), do: Process.put(@touched, true)
  end
end
