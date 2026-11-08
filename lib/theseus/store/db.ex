Postgrex.Types.define(Theseus.Store.PostgresTypes, [], json: JSON)

defmodule Theseus.Store.DB do
  @moduledoc """
  The store's Postgres side (see `Theseus.Store`): the connection pool, the
  SQL for reads and writes, and the app's tables.

  Config `:store` (`THESEUS_DATABASE_URL` sets `url`): `url`, `schema` (the
  Postgres schema holding the app's tables; by default the ledger file's
  name), `pool_size` (default 10) and `preview: true`, which rolls back
  every transaction and creates no tables. Without a url the app has no
  store, unless `memory: true`: then the rows live in this process,
  starting with the seed units' rows (`Theseus.Seed`), as on a preview
  with made-up data.

  The tables are those of the live branch's schema units. They are created
  at boot and when a schema unit is registered or promoted on the live
  branch, before it goes live (prepare/2); a promotion whose tables cannot
  be created fails.
  """

  use GenServer
  require Logger

  alias Theseus.{Branches, Ledger, Schema, Store}

  @pool Theseus.Store.Pool
  @tables {__MODULE__, :tables}
  @overlay {__MODULE__, :overlay}
  @retry_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  defp config, do: Application.get_env(:theseus, :store, [])

  @doc "Whether a database is configured."
  def configured?, do: config()[:url] not in [nil, ""]

  @doc "Whether this node only previews: every transaction is rolled back."
  def preview?, do: config()[:preview] == true

  @doc "Whether the rows are kept in memory, without a database."
  def memory?, do: config()[:memory] == true and not configured?()

  @doc false
  # In memory mode: the rows and their version, seeded on first use.
  def memory_rows, do: GenServer.call(__MODULE__, :memory_rows, 30_000)

  @doc false
  # In memory mode: replaces the rows, unless another request changed them
  # since `version` was read.
  def memory_commit(version, rows),
    do: GenServer.call(__MODULE__, {:memory_commit, version, rows})

  @doc """
  The live tables, once created: nil when the app has none (or no
  database), `{:unavailable, reason}` while they cannot be reached.
  """
  def tables, do: :persistent_term.get(@tables, nil)

  @doc "The Postgres schema holding the app's tables."
  def prefix do
    case config()[:schema] do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        Application.fetch_env!(:theseus, :ledger_path)
        |> Path.basename()
        |> Path.rootname()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_]/, "_")
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    :persistent_term.put(@tables, nil)

    cond do
      configured?() ->
        {:ok, _} =
          Postgrex.start_link([name: @pool, types: Theseus.Store.PostgresTypes] ++ connection())

        # Shadow runs of endpoint units read on their own connections, so
        # they never take one a live request is waiting for.
        unless preview?() do
          {:ok, _} =
            Postgrex.start_link(
              [name: Theseus.Store.ShadowPool, types: Theseus.Store.PostgresTypes] ++
                Keyword.put(connection(), :pool_size, 4)
            )
        end

        send(self(), :refresh)

      memory?() ->
        send(self(), :refresh)

      true ->
        :ok
    end

    {:ok, %{rows: nil, version: 0}}
  end

  defp connection do
    uri = URI.parse(config()[:url])
    [user, password] = String.split(uri.userinfo || "postgres", ":", parts: 2) |> pad()

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: URI.decode(user),
      password: password && URI.decode(password),
      database: String.trim_leading(uri.path || "/postgres", "/"),
      pool_size: config()[:pool_size] || 10,
      backoff_type: :exp
    ]
  end

  defp pad([user]), do: [user, nil]
  defp pad(pair), do: pair

  @impl true
  def handle_call(:memory_rows, _from, %{rows: nil} = state) do
    rows =
      case Theseus.Seed.rows(Theseus.Seed.units(Branches.live()), DateTime.utc_now(), tables()) do
        {:ok, rows} ->
          rows

        {:error, why} ->
          Logger.warning("the seed units' rows were not used: #{why}")
          %{}
      end

    {:reply, {0, rows}, %{state | rows: rows}}
  end

  def handle_call(:memory_rows, _from, state), do: {:reply, {state.version, state.rows}, state}

  def handle_call({:memory_commit, version, rows}, _from, %{version: version} = state),
    do: {:reply, :ok, %{state | rows: rows, version: version + 1}}

  def handle_call({:memory_commit, _version, _rows}, _from, state), do: {:reply, :stale, state}

  @impl true
  def handle_info(:refresh, state) do
    case refresh() do
      :ok ->
        :ok

      {:error, reason} ->
        Process.send_after(self(), :refresh, @retry_ms) && Logger.warning(reason)
    end

    {:noreply, state}
  end

  ## Tables

  @doc "The schema units on a branch and their tables: `[{module, tables}]`."
  def schema_units(branch) do
    Ledger.memo({:schema_units, branch}, fn ->
      for u <- Branches.units(branch),
          {:ok, %{ast: ast}} <- [Ledger.version(u.module, u.current_version)],
          ast != nil and Schema.schema_unit?(ast),
          {:ok, tables} <- [Schema.from_ast(ast)],
          do: {u.module, tables}
    end)
  end

  @doc """
  Whether a schema unit's proposed version may replace its current one on
  a branch: it reads, no table is declared twice, and what it takes away or
  requires can be done (`Theseus.Store.Migrate.check/5`). `others` are the
  other versions of the change's group.
  """
  @spec check(Theseus.Version.t(), String.t(), [Theseus.Version.t()]) ::
          :ok | {:error, [String.t()]}
  def check(%{unit: module, ast: ast} = version, branch, others \\ []) do
    with {:ok, new} <- Schema.from_ast(ast) |> reasons(),
         {:ok, before} <- branch_tables(branch) |> reasons(),
         {:ok, after_} <-
           with_unit(schema_units(branch), module, new) |> Schema.merge() |> reasons() do
      Theseus.Store.Migrate.check(version, before, after_, branch, others)
    end
  end

  @doc "A branch's tables, from its schema units."
  def branch_tables(branch),
    do: branch |> schema_units() |> Enum.map(&elem(&1, 1)) |> Schema.merge()

  defp reasons({:error, why}) when is_binary(why), do: {:error, [why]}
  defp reasons(ok), do: ok

  defp with_unit(units, module, tables),
    do: for({m, t} <- units, m != module, do: t) ++ [tables]

  @doc """
  Before a version of a schema unit goes live: creates the tables it adds,
  and when it takes things away, makes columns required or has a new
  backfill/2, migrates the data in one transaction
  (`Theseus.Store.Migrate.run/4`) and records `{:schema_migrated, unit,
  summary}`. Anything else returns :ok.
  """
  @spec prepare(Theseus.Version.t(), boolean()) :: :ok | {:error, String.t()}
  def prepare(%{unit: module, ast: ast} = version, true = _live?) do
    if ast != nil and Schema.schema_unit?(ast) do
      live = Branches.live()

      with {:ok, tables} <- Schema.from_ast(ast),
           {:ok, before} <- branch_tables(live),
           {:ok, merged} <- schema_units(live) |> with_unit(module, tables) |> Schema.merge() do
        plan = Schema.plan(before, merged)
        backfill? = Theseus.Store.Migrate.backfill?(version, plan, live)

        if configured?() and not preview?() and (backfill? or not Schema.additive?(plan)),
          do: migrate(version, before, merged, backfill?),
          else: ensure(merged)
      end
    else
      :ok
    end
  end

  def prepare(_version, false), do: :ok

  defp migrate(%{unit: module} = version, before, merged, backfill?) do
    case Theseus.Store.Migrate.run(version, before, merged, backfill?) do
      {:ok, summary} ->
        {:ok, _} =
          Ledger.append({:schema_migrated, module, summary},
            actor: :system,
            unit: module,
            branch: Branches.live()
          )

        put(merged)

      {:error, why} ->
        {:error, why}
    end
  end

  @doc "Creates the live branch's tables that are missing. At boot and after a rollback or switch."
  @spec refresh() :: :ok | {:error, String.t()}
  def refresh do
    case schema_units(Branches.live()) |> Enum.map(&elem(&1, 1)) |> Schema.merge() do
      {:ok, tables} -> ensure(tables)
      {:error, why} -> {:error, why}
    end
  end

  @doc "After a rollback, removal or switch: the live tables again."
  def changed do
    if configured?() or memory?() do
      case refresh() do
        :ok -> :ok
        {:error, why} -> Logger.warning("the app's tables: #{why}")
      end
    end

    :ok
  end

  defp ensure(tables) when map_size(tables) == 0 do
    :persistent_term.put(@tables, nil)
    :ok
  end

  defp ensure(tables) do
    cond do
      memory?() ->
        put(tables)

      not configured?() ->
        {:error, "the app's schema units need a database: set THESEUS_DATABASE_URL"}

      # The leader creates and migrates the tables; a follower uses them.
      preview?() or Theseus.Leader.follower?() ->
        put(tables)

      true ->
        statements = Schema.ddl(prefix(), tables)

        result =
          Postgrex.transaction(@pool, fn conn ->
            Enum.each(statements, &Postgrex.query!(conn, &1, []))
          end)

        case result do
          {:ok, _} -> put(tables)
          {:error, reason} -> unavailable("could not create the app's tables: #{inspect(reason)}")
        end
    end
  rescue
    e -> unavailable("could not create the app's tables: #{Exception.message(e)}")
  end

  defp put(tables) do
    :persistent_term.put(@tables, tables)
    :persistent_term.erase({__MODULE__, :preview_differing})
    :ok
  end

  @doc false
  # On a preview of live data, inside each request's transaction: the tables
  # whose shape on the branch differs from the live database get overlays
  # (overlay!/2), so the branch's code reads them as the branch has them and
  # writes beside them. No table is altered or locked, and everything goes
  # with the rollback. A preview whose tables are the live ones runs
  # nothing.
  def preview_schema(conn) do
    tables = tables() || %{}

    differing =
      case :persistent_term.get({__MODULE__, :preview_differing}, nil) do
        nil ->
          d = differing(conn, tables)
          :persistent_term.put({__MODULE__, :preview_differing}, d)
          d

        d ->
          d
      end

    if differing != [], do: overlay!(conn, Map.take(tables, differing))
    :ok
  end

  @doc false
  # After a preview request's transaction: its overlays went with it.
  def end_overlay, do: Process.delete(@overlay)

  @doc """
  The tables whose shape in `tables` differs from the database's: missing
  there, with other columns, or with a column `tables` lets be empty that
  the database requires.
  """
  @spec differing(DBConnection.conn(), Schema.tables()) :: [atom()]
  def differing(conn, tables) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT table_name, column_name, is_nullable FROM information_schema.columns WHERE table_schema = $1",
        [prefix()]
      )

    live = Enum.group_by(rows, &hd/1, fn [_, c, nullable] -> {c, nullable == "YES"} end)

    for {t, %{columns: cols}} <- Enum.sort(tables),
        have = Map.new(live[Atom.to_string(t)] || []),
        have == %{} or
          MapSet.new(Map.keys(have)) != MapSet.new(cols, fn {c, _} -> Atom.to_string(c) end) or
          Enum.any?(cols, fn {c, spec} -> spec.null and have[Atom.to_string(c)] == false end),
        do: t
  end

  defp unavailable(reason) do
    if not match?(%{}, tables()), do: :persistent_term.put(@tables, {:unavailable, reason})
    {:error, reason}
  end

  ## Transactions

  @doc false
  def transaction(fun) do
    Postgrex.transaction(@pool, fn conn ->
      Postgrex.query!(conn, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
      Postgrex.query!(conn, "SET LOCAL statement_timeout = 5000", [])
      fun.(conn)
    end)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] == :serialization_failure,
        do: {:error, :serialization_failure},
        else: reraise(e, __STACKTRACE__)
  end

  @doc false
  def rollback(conn, reason), do: DBConnection.rollback(conn, reason)

  ## Reads

  @doc false
  def all(conn, tables, q) do
    scope = scope!(tables, q)
    {where, params} = where(q.where, scope)
    {search, rank, params} = search(Map.get(q, :search), scope, where, params)
    where = where <> search
    names = scope.base.columns |> Map.keys() |> Enum.sort()

    joined =
      for {name, j} <- scope.order, do: {name, j, j.columns |> Map.keys() |> Enum.sort()}

    select =
      Enum.map(names, &~s|"t0".#{Schema.quote_name(&1)}|) ++
        for({_name, j, cols} <- joined, c <- cols, do: ~s|"#{j.alias}".#{Schema.quote_name(c)}|)

    order =
      Enum.map_join(q.order ++ [asc: :id], ", ", fn {dir, path} ->
        {ref, spec} = ref!(scope, path)
        "#{ref}#{collate(spec)} #{if dir == :asc, do: "ASC", else: "DESC"}"
      end)

    order = if rank, do: "#{rank} DESC, " <> order, else: order

    sql =
      "SELECT #{Enum.join(select, ", ")} FROM #{from(scope)}" <>
        where <> " ORDER BY #{order} LIMIT #{q.limit} OFFSET #{q.offset}"

    %{rows: rows} = Postgrex.query!(conn, sql, params)

    Enum.map(rows, fn values ->
      {base, rest} = Enum.split(values, length(names))
      row = names |> Enum.zip(base) |> Map.new()

      {row, []} =
        Enum.reduce(joined, {row, rest}, fn {name, _j, cols}, {row, rest} ->
          {mine, rest} = Enum.split(rest, length(cols))
          other = cols |> Enum.zip(mine) |> Map.new()
          {Map.put(row, name, if(other.id == nil, do: nil, else: other)), rest}
        end)

      row
    end)
  end

  @doc false
  def count(conn, tables, q) do
    scope = scope!(tables, q)
    {where, params} = where(q.where, scope)
    {search, _rank, params} = search(Map.get(q, :search), scope, where, params)
    where = where <> search
    %{rows: [[n]]} = Postgrex.query!(conn, "SELECT count(*) FROM #{from(scope)}" <> where, params)
    n
  end

  @doc false
  def aggregate(conn, tables, %{table: table, by: by, compute: compute} = q) do
    scope = scope!(tables, q)
    check_figures!(scope, table, compute)
    {where, params} = where(q.where, scope)
    by_refs = for {_name, path} <- by, do: elem(ref!(scope, path), 0)

    figures =
      for {name, f} <- compute, do: "#{figure_sql(scope, f)} AS #{Schema.quote_name(name)}"

    order =
      Enum.map(q.order, fn {dir, name} ->
        dir = if dir == :asc, do: "ASC", else: "DESC"

        if Keyword.has_key?(by, name) do
          {ref, spec} = ref!(scope, by[name])
          "#{ref}#{collate(spec)} #{dir}"
        else
          "#{Schema.quote_name(name)} #{dir}"
        end
      end)

    sql =
      "SELECT #{Enum.join(by_refs ++ figures, ", ")} FROM #{from(scope)}" <>
        where <>
        if(by == [], do: "", else: " GROUP BY #{Enum.join(by_refs, ", ")}") <>
        if(order == [], do: "", else: " ORDER BY #{Enum.join(order, ", ")}") <>
        " LIMIT #{q.limit}"

    %{rows: rows} = Postgrex.query!(conn, sql, params)
    names = Keyword.keys(by) ++ Keyword.keys(compute)
    Enum.map(rows, fn row -> names |> Enum.zip(row) |> Map.new() end)
  end

  defp figure_sql(_scope, :count), do: "count(*)"
  defp figure_sql(scope, {:count, c}), do: "count(#{elem(ref!(scope, c), 0)})"
  defp figure_sql(scope, {:sum, c}), do: "COALESCE(sum(#{elem(ref!(scope, c), 0)}), 0)::bigint"

  defp figure_sql(scope, {f, c}) when f in [:min, :max] do
    {ref, spec} = ref!(scope, c)
    "#{f}(#{ref}#{collate(spec)})"
  end

  @doc false
  # The figures aggregate/2 may compute over a table's columns.
  def check_figures!(%{base: _} = scope, table, compute) do
    for {_name, {f, path}} <- compute do
      {_ref, spec} = ref!(scope, path)
      check_figure!(f, spec, table, path)
    end

    :ok
  end

  def check_figures!(columns, table, compute) do
    for {_name, {f, c}} <- compute do
      spec = columns[c] || raise ArgumentError, "table #{table} has no column #{inspect(c)}"
      check_figure!(f, spec, table, c)
    end

    :ok
  end

  defp check_figure!(f, spec, table, c) do
    c = with {j, col} <- c, do: "#{j}.#{col}"

    cond do
      f == :sum and spec.type != :integer ->
        raise ArgumentError, "#{table}.#{c} is not an integer column, so it has no sum"

      f in [:min, :max] and spec.type not in [:integer, :text, :utc_datetime] ->
        raise ArgumentError, "#{table}.#{c} holds #{spec.type}, which has no #{f}"

      true ->
        :ok
    end
  end

  # The tables a query reads: the table as "t0", each join as "j1", "j2"...
  defp scope!(tables, %{table: table} = q) do
    columns = columns!(tables, table)

    base = %{alias: "t0", table: table, columns: columns}

    # Each join starts from a column of the table or of an earlier join.
    {joins, _scope} =
      Map.get(q, :joins, [])
      |> Enum.with_index(1)
      |> Enum.map_reduce(%{base: base, joins: %{}}, fn {{name, {other, from}}, i}, scope ->
        if Map.has_key?(columns, name),
          do: raise(ArgumentError, "join: #{name} is already a column of #{table}")

        {on, spec} = ref!(scope, from)

        unless match?(%{type: :text}, spec),
          do:
            raise(
              ArgumentError,
              "join: #{inspect(from)} is not a text column, so it names no row"
            )

        j = %{alias: "j#{i}", table: other, columns: columns!(tables, other), on: on}
        {{name, j}, %{scope | joins: Map.put(scope.joins, name, j)}}
      end)

    %{base: base, joins: Map.new(joins), order: joins}
  end

  defp from(scope) do
    "#{source(scope.base.table)} AS \"t0\"" <>
      Enum.map_join(scope.order, fn {_name, j} ->
        ~s| LEFT JOIN #{source(j.table)} AS "#{j.alias}" ON "#{j.alias}"."id" = #{j.on}|
      end)
  end

  # A word search: every word in one of the columns, and its rank, how often
  # the words appear, for the order. Words come lowercased (ASCII), and
  # columns are lowercased under "C", which changes ASCII letters only.
  defp search(nil, _scope, _where, params), do: {"", nil, params}

  defp search(%{columns: columns, words: words}, scope, where, params) do
    refs =
      for c <- columns do
        {ref, spec} = ref!(scope, c)

        unless spec.type == :text,
          do: raise(ArgumentError, "search: #{inspect(c)} is not a text column")

        ~s|lower(coalesce(#{ref}, '') COLLATE "C")|
      end

    {marks, params} =
      Enum.map_reduce(words, params, fn w, params ->
        {"$#{length(params) + 1}::text", params ++ [w]}
      end)

    conditions =
      Enum.map(marks, fn m ->
        "(" <> Enum.map_join(refs, " OR ", &"strpos(#{&1}, #{m}) > 0") <> ")"
      end)

    rank =
      "(" <>
        Enum.map_join(for(r <- refs, m <- marks, do: {r, m}), " + ", fn {r, m} ->
          "(length(#{r}) - length(replace(#{r}, #{m}, ''))) / length(#{m})"
        end) <> ")"

    joiner = if where == "", do: " WHERE ", else: " AND "
    {joiner <> Enum.join(conditions, " AND "), rank, params}
  end

  # A column of the query as SQL, with its spec.
  defp ref!(scope, {join, column}) do
    case scope.joins[join] do
      nil -> raise ArgumentError, "#{inspect(join)} is not a join of this query"
      j -> column_ref(j, column)
    end
  end

  defp ref!(scope, column), do: column_ref(scope.base, column)

  defp column_ref(%{alias: a, table: table, columns: columns}, column) do
    name = name!(columns, table, column)
    {if(a, do: ~s|"#{a}".#{name}|, else: name), columns[column]}
  end

  defp columns!(tables, table) do
    case tables[table] do
      %{columns: columns} -> columns
      nil -> raise ArgumentError, "there is no table #{inspect(table)} in the app's schema units"
    end
  end

  defp name!(columns, table, column) do
    if Map.has_key?(columns, column),
      do: Schema.quote_name(column),
      else: raise(ArgumentError, "table #{table} has no column #{inspect(column)}")
  end

  # Text compares by bytes, as in the in-memory store.
  defp collate(%{type: :text}), do: ~s( COLLATE "C")
  defp collate(_column), do: ""

  defp qualified(table), do: "#{Schema.quote_name(prefix())}.#{Schema.quote_name(table)}"

  # Where a read finds a table's rows: the table, or for a replay side the
  # table with the side's own writes laid over it (see overlay!/2).
  defp source(table) do
    case Process.get(@overlay) do
      %{^table => %{source: source}} -> source
      _ -> qualified(table)
    end
  end

  ## Replay sides

  @doc """
  For a replay side (`Theseus.Store.Side`), in its transaction: the side's
  writes go to temporary tables of its own, one per table in `tables`, and
  its reads see the app's rows with those writes laid over them. The app's
  tables are only read, so a side takes no row lock and runs no
  `ALTER TABLE` on them, and no live request waits for it. The tables as
  `tables` has them are read from the app's: a column the app's table lacks
  reads as its default or empty, and a table it lacks starts empty. The
  temporary tables go with the transaction. For this process only.
  """
  @spec overlay!(DBConnection.conn(), Schema.tables()) :: :ok
  def overlay!(conn, tables) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = $1",
        [prefix()]
      )

    live = Enum.group_by(rows, &hd/1, &List.last/1)

    sources =
      for {{table, %{columns: columns}}, i} <- Enum.with_index(Enum.sort(tables)), into: %{} do
        names = columns |> Map.keys() |> Enum.sort()
        q = &Schema.quote_name/1
        own = "pg_temp.#{q.("theseus_side_#{i}")}"

        defs =
          Enum.map_join(names, ", ", fn c ->
            "#{q.(c)} #{Schema.sql_type(columns[c].type)}" <>
              if(c == :id, do: " PRIMARY KEY", else: "")
          end)

        Postgrex.query!(
          conn,
          ~s|CREATE TEMP TABLE #{q.("theseus_side_#{i}")} (#{defs}, "__gone" boolean NOT NULL DEFAULT false) ON COMMIT DROP|,
          []
        )

        list = Enum.map_join(names, ", ", q)
        written = ~s|SELECT #{list} FROM #{own} WHERE NOT "__gone"|

        rows =
          case live[Atom.to_string(table)] do
            nil ->
              written

            have ->
              projected =
                Enum.map_join(names, ", ", fn c ->
                  if Atom.to_string(c) in have,
                    do: "b.#{q.(c)}",
                    else: "#{missing(columns[c])} AS #{q.(c)}"
                end)

              ~s|SELECT #{projected} FROM #{qualified(table)} b WHERE NOT EXISTS (SELECT 1 FROM #{own} o WHERE o."id" = b."id") UNION ALL #{written}|
          end

        {table, %{source: "(#{rows})", own: own, names: names}}
      end

    Process.put(@overlay, sources)
    :ok
  end

  defp missing(%{type: type, default: nil}), do: "NULL::#{Schema.sql_type(type)}"

  defp missing(%{type: type, default: d}),
    do: "#{Schema.literal_sql(type, d)}::#{Schema.sql_type(type)}"

  # On a replay side, every write goes to the side's own tables.
  defp write(conn, tables, write, mode) do
    table = elem(write, 1)

    case Process.get(@overlay) do
      nil -> apply_write(conn, tables, write, mode)
      %{^table => o} -> side_write(conn, tables, o, write, mode)
      _ -> raise ArgumentError, "there is no table #{inspect(table)} in the app's schema units"
    end
  end

  # A side's write, to its own table. An update or delete finds the row as
  # the side sees it, and the whole row is written.
  defp side_write(conn, tables, o, {:insert, table, id, row, _}, mode) do
    row = complete_row!(tables, table, row)

    cond do
      find(conn, tables, table, id, []) == nil -> put_own(conn, o, row, false)
      mode == :replay -> :ok
      true -> {:conflict, "#{table} already has a row with id #{inspect(id)}"}
    end
  end

  defp side_write(conn, tables, o, {kind, table, id, changes, where}, _mode) do
    changes = values!(columns!(tables, table), table, changes)

    case {kind, find(conn, tables, table, id, where)} do
      {_, nil} -> {:conflict, "#{table} #{id} changed or is gone"}
      {:update, row} -> put_own(conn, o, Map.merge(row, changes), false)
      {:delete, _row} -> put_own(conn, o, %{id: id}, true)
    end
  end

  defp find(conn, tables, table, id, where) do
    query = %{table: table, where: [{:id, id} | where], order: [], limit: 1, offset: 0}

    case all(conn, tables, query) do
      [row] -> row
      [] -> nil
    end
  end

  defp put_own(conn, o, row, gone?) do
    names = o.names
    q = &Schema.quote_name/1
    columns = Enum.map_join(names, ", ", q) <> ~s|, "__gone"|
    marks = Enum.map_join(1..(length(names) + 1), ", ", &"$#{&1}")
    set = Enum.map_join(names -- [:id], ", ", &"#{q.(&1)} = EXCLUDED.#{q.(&1)}")

    set =
      if set == "",
        do: ~s|"__gone" = EXCLUDED."__gone"|,
        else: set <> ~s|, "__gone" = EXCLUDED."__gone"|

    Postgrex.query!(
      conn,
      ~s|INSERT INTO #{o.own} (#{columns}) VALUES (#{marks}) ON CONFLICT ("id") DO UPDATE SET #{set}|,
      Enum.map(names, &Map.get(row, &1)) ++ [gone?]
    )

    :ok
  end

  defp where([], _scope), do: {"", []}

  defp where(conditions, scope) do
    {sql, params} =
      Enum.reduce(conditions, {[], []}, fn {path, condition}, {sql, params} ->
        {ref, spec} = ref!(scope, path)
        name = ref <> collate(spec)
        n = length(params) + 1

        case condition do
          {op, _text} when op in [:contains, :icontains] and spec.type != :text ->
            raise ArgumentError, "#{op} compares text only, not #{spec.type}"

          {:contains, text} ->
            {sql ++ ["strpos(#{ref}, $#{n}) > 0"], params ++ [text]}

          # Under the "C" collation, lower/1 changes ASCII letters only.
          {:icontains, text} ->
            {sql ++ [~s|strpos(lower(#{ref} COLLATE "C"), lower($#{n}::text COLLATE "C")) > 0|],
             params ++ [text]}

          nil ->
            {sql ++ ["#{name} IS NULL"], params}

          {:not, nil} ->
            {sql ++ ["#{name} IS NOT NULL"], params}

          {:in, values} ->
            {sql ++ ["#{name} = ANY($#{n})"], params ++ [values]}

          {:!=, v} ->
            {sql ++ ["#{name} <> $#{n}"], params ++ [v]}

          {op, v} when op in [:<, :<=, :>, :>=] ->
            {sql ++ ["#{name} #{op} $#{n}"], params ++ [v]}

          v ->
            {sql ++ ["#{name} = $#{n}"], params ++ [v]}
        end
      end)

    {" WHERE " <> Enum.join(sql, " AND "), params}
  end

  ## Writes

  @doc false
  # Applies writes in order. An update or delete that finds no matching row
  # is a conflict: the row changed or went since the unit read it. In
  # `:replay` mode an insert whose row exists leaves it as it is (see
  # `Theseus.Store.Side`).
  def apply_writes(conn, tables, ops, mode \\ :strict)

  def apply_writes(_conn, _tables, [], _mode), do: :ok

  def apply_writes(conn, tables, ops, mode) do
    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case Store.write!(op) do
        {:error, why} -> raise ArgumentError, why
        write -> {:cont, write(conn, tables, write, mode)} |> halt_on_conflict()
      end
    end)
  end

  @doc false
  # A row's values checked against a table's columns: names, types and
  # which may be empty. With no tables known (a spec on a node without
  # them), the row as it is.
  def check_row!(nil, _table, row), do: row
  def check_row!(tables, table, row), do: values!(columns!(tables, table), table, row)

  @doc false
  # A row to insert: checked, with every required column present and the
  # defaults and empty columns filled in, as the table would hold it.
  def complete_row!(nil, _table, row), do: row

  def complete_row!(tables, table, row) do
    columns = columns!(tables, table)
    row = values!(columns, table, row)
    require_columns!(columns, table, row)

    Map.new(columns, fn {name, spec} -> {name, Map.get(row, name, spec.default)} end)
  end

  defp require_columns!(columns, table, row) do
    missing =
      for {name, %{null: false, default: nil}} <- columns, not Map.has_key?(row, name), do: name

    if missing != [],
      do: raise(ArgumentError, "an insert into #{table} needs #{Enum.join(missing, ", ")}")
  end

  ## Snapshots, for validation

  @snapshot_ms 10 * 60_000

  @doc """
  Exports a snapshot of the data for a validation (see `Theseus.Store.Side`).
  Returns the holder, which keeps the snapshot open until
  `release_snapshot/1`, and the snapshot id.
  """
  @spec export_snapshot() :: {:ok, pid(), String.t()} | {:error, String.t()}
  def export_snapshot do
    parent = self()
    holder = spawn_link(fn -> hold_snapshot(parent) end)

    receive do
      {:snapshot, ^holder, id} ->
        {:ok, holder, id}

      {:snapshot_failed, ^holder, why} ->
        {:error, why}
    after
      15_000 ->
        Process.exit(holder, :kill)
        {:error, "the snapshot did not open in time"}
    end
  end

  @doc "Lets a snapshot go."
  @spec release_snapshot(pid()) :: :ok
  def release_snapshot(holder) do
    send(holder, :release)
    :ok
  end

  defp hold_snapshot(parent) do
    Postgrex.transaction(
      @pool,
      fn conn ->
        Postgrex.query!(conn, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
        %{rows: [[id]]} = Postgrex.query!(conn, "SELECT pg_export_snapshot()", [])
        send(parent, {:snapshot, self(), id})

        receive do
          :release -> :ok
        after
          @snapshot_ms -> :ok
        end

        DBConnection.rollback(conn, :released)
      end,
      timeout: :infinity
    )
  rescue
    e -> send(parent, {:snapshot_failed, self(), Exception.message(e)})
  end

  @doc false
  # How to reach the database, for the sandbox's sides.
  def connection_opts,
    do: Keyword.take(connection(), [:hostname, :port, :username, :password, :database])

  defp halt_on_conflict({:cont, {:conflict, _} = c}), do: {:halt, c}
  defp halt_on_conflict(cont), do: cont

  defp apply_write(conn, tables, {:insert, table, id, row, _}, mode) do
    # Every column is written, defaults included, so a row does not depend
    # on the defaults the database holds.
    row = complete_row!(tables, table, row)
    names = row |> Map.keys() |> Enum.sort()
    marks = Enum.map_join(1..length(names), ", ", &"$#{&1}")

    sql =
      "INSERT INTO #{qualified(table)} (#{Enum.map_join(names, ", ", &Schema.quote_name/1)}) VALUES (#{marks})" <>
        replay_conflict(mode, names)

    case Postgrex.query(conn, sql, Enum.map(names, &row[&1])) do
      {:ok, _} ->
        :ok

      # Another request took the id first: run the call again (Theseus.Store.run/3).
      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        {:conflict, "#{table} already has a row with id #{inspect(id)}"}

      {:error, e} ->
        raise e
    end
  end

  defp apply_write(conn, tables, {kind, table, id, changes, where}, _mode) do
    columns = columns!(tables, table)
    changes = values!(columns, table, changes)
    scope = %{base: %{alias: nil, table: table, columns: columns}, joins: %{}}
    {where_sql, params} = where([{:id, id} | where], scope)

    {sql, params} =
      case kind do
        :update ->
          names = changes |> Map.keys() |> Enum.sort()
          offset = length(params)

          set =
            names
            |> Enum.with_index(offset + 1)
            |> Enum.map_join(", ", fn {name, i} -> "#{Schema.quote_name(name)} = $#{i}" end)

          {"UPDATE #{qualified(table)} SET #{set}" <> where_sql,
           params ++ Enum.map(names, &changes[&1])}

        :delete ->
          {"DELETE FROM #{qualified(table)}" <> where_sql, params}
      end

    case Postgrex.query!(conn, sql, params) do
      %{num_rows: 1} -> :ok
      _ -> {:conflict, "#{table} #{id} changed or is gone"}
    end
  end

  # A recorded insert's row is usually there already: the data as it is now
  # wins, on both sides.
  defp replay_conflict(:strict, _names), do: ""
  defp replay_conflict(:replay, _names), do: ~s| ON CONFLICT ("id") DO NOTHING|

  defp values!(columns, table, row) do
    Map.new(row, fn {name, value} ->
      case columns[name] do
        nil ->
          raise ArgumentError, "table #{table} has no column #{inspect(name)}"

        %{null: null, type: type} ->
          value = Store.value(value)

          cond do
            value == nil and null ->
              {name, nil}

            value == nil ->
              raise ArgumentError, "#{table}.#{name} cannot be empty"

            Schema.type?(type, value) ->
              {name, value}

            true ->
              raise ArgumentError,
                    "#{table}.#{name} holds #{type}, not #{inspect(value, limit: 3)}"
          end
      end
    end)
  end
end
