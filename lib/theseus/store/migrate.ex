defmodule Theseus.Store.Migrate do
  @moduledoc """
  Schema changes that do more than add (see `Theseus.Schema.plan/2`):
  dropping tables, columns and indexes, making columns required, and
  backfills.

    * `check/5`, in the static stage: refuses type changes, a required
      column without backfill/2, and a drop while a unit on the branch,
      after the change's group, still mentions what it drops. A unit
      mentions a table when its code has the table's name as an atom, and a
      column when it has both the table's and the column's names, so the
      check errs towards refusing.
    * `preview/3`, on the sandbox: runs backfill/2 over the app's data (up
      to #{2_000} rows a table) and reports what it would change.
    * `run/4`, at promotion on the live branch: in one transaction, adds
      what is new, runs backfill/2 over every row, makes columns required,
      then drops. A required column a row still lacks fails the promotion
      and changes nothing. The ledger records `{:schema_migrated, unit,
      summary}`.
    * `rollback_refusal/3`: a unit or schema version that mentions a table
      or column a migration dropped is not rolled back to, since its data
      is gone.

  backfill/2 runs when the change makes a column required, or when its
  code differs from the current version's.
  """

  alias Theseus.{Branches, Event, Ledger, Schema, Store, Unit, Version}
  alias Theseus.Store.{DB, Side}

  @pool Theseus.Store.Pool
  @batch 500
  @preview_rows 2_000

  ## Checking a change

  @doc """
  The reasons a schema unit's proposed version cannot replace its current
  one, given the branch's tables before and after and the other versions
  of the change's group.
  """
  @spec check(Version.t(), Schema.tables(), Schema.tables(), String.t(), [Version.t()]) ::
          :ok | {:error, [String.t()]}
  def check(%Version{unit: module, ast: ast}, before, after_, branch, others) do
    plan = Schema.plan(before, after_)

    reasons =
      Schema.refusals(plan, Schema.backfill?(ast)) ++
        in_use(plan, units(branch, others, module))

    if reasons == [], do: :ok, else: {:error, reasons}
  end

  # What a drop takes away while a unit still mentions it.
  defp in_use(plan, units) do
    for(
      t <- plan.drop_tables,
      users = for({m, atoms} <- units, t in atoms, do: m),
      users != [],
      do:
        "it drops table #{t}, which #{names(users)} still mention; change them first, or in the same group"
    ) ++
      for(
        {t, c} <- plan.drop_columns,
        users = for({m, atoms} <- units, t in atoms and c in atoms, do: m),
        users != [],
        do:
          "it drops #{t}.#{c}, which #{names(users)} still mention; change them first, or in the same group"
      )
  end

  defp names(modules), do: Enum.map_join(modules, ", ", &inspect/1)

  # The branch's units other than specs and schema units, with the group's
  # versions in place of their current ones: `[{module, atoms}]`.
  defp units(branch, others, self) do
    proposed =
      for %Version{unit: m, ast: ast} <- others, ast != nil, not Unit.spec_name?(m), into: %{} do
        {m, ast}
      end

    current =
      for u <- Branches.units(branch),
          u.kind != :spec,
          not Map.has_key?(proposed, u.module),
          {:ok, %Version{ast: ast}} <- [Ledger.version(u.module, u.current_version)],
          ast != nil,
          into: %{},
          do: {u.module, ast}

    for {m, ast} <- Map.merge(current, proposed),
        m != self,
        not Schema.schema_unit?(ast),
        do: {m, Schema.mentions(ast)}
  end

  @doc """
  Whether backfill/2 runs when `version` is promoted: it makes a column
  required, or its backfill/2 differs from the current version's.
  """
  @spec backfill?(Version.t(), Schema.plan(), String.t()) :: boolean()
  def backfill?(%Version{unit: module, ast: ast}, plan, branch) do
    current =
      with hash when is_binary(hash) <- Ledger.current(module, branch),
           {:ok, %Version{ast: old}} when old != nil <- Ledger.version(module, hash),
           do: Schema.backfill_defs(old),
           else: (_ -> [])

    Schema.backfill?(ast) and (plan.required != [] or Schema.backfill_defs(ast) != current)
  end

  ## Validation

  @doc """
  Runs backfill/2 (`module`, a candidate loaded on the sandbox) over the
  app's data on the snapshot: `{:info, detail}`, `{:fail, detail}` when it
  raises, sets something the tables refuse or leaves a required column
  empty, or `{:skip, detail}` without data.
  """
  def preview(module, before, ctx) do
    plan = Schema.plan(before, ctx.store_tables)
    {side, data} = Side.start(snapshot: ctx[:snapshot], tables: ctx.store_tables)

    try do
      if data == :memory do
        {:skip, %{reason: "there is no data to fill here; it runs over every row when approved"}}
      else
        tables =
          for {t, _} <- Enum.sort(before), Map.has_key?(ctx.store_tables, t) do
            {rows, _} = Side.run(side, fn -> Store.all(t, limit: @preview_rows) end)
            preview_table(module, t, rows, ctx.store_tables, plan)
          end

        detail = %{tables: tables}

        if Enum.any?(tables, &(&1.errors != [] or &1.unfilled != [])),
          do: {:fail, detail},
          else: {:info, detail}
      end
    after
      Side.stop(side)
    end
  end

  defp preview_table(module, table, rows, tables, plan) do
    results = for row <- rows, do: {row, changes(module, table, row, tables)}
    changed = for {row, {:ok, c}} <- results, c != %{}, do: {row, c}
    errors = for {_row, {:error, why}} <- results, do: why

    unfilled =
      for {^table, c} <- plan.required,
          n = Enum.count(results, fn {row, r} -> filled(row, r)[c] == nil end),
          n > 0,
          do: %{column: c, rows: n}

    %{
      table: table,
      rows: length(rows),
      more: length(rows) == @preview_rows,
      changed: length(changed),
      samples: for({row, c} <- Enum.take(changed, 3), do: %{id: row.id, set: c}),
      errors: errors |> Enum.uniq() |> Enum.take(3),
      unfilled: unfilled
    }
  end

  defp filled(row, {:ok, c}), do: Map.merge(row, c)
  defp filled(row, _error), do: row

  # What backfill/2 sets on a row, checked against the tables.
  defp changes(module, table, row, tables) do
    case module.backfill(table, row) do
      nil ->
        {:ok, %{}}

      %{} = c ->
        cond do
          Map.has_key?(c, :id) -> {:error, "backfill/2 may not set id"}
          true -> {:ok, DB.check_row!(tables, table, c)}
        end

      other ->
        {:error, "backfill/2 returned #{inspect(other, limit: 5)}; it returns a map or nil"}
    end
  rescue
    e in FunctionClauseError ->
      if e.function == :backfill,
        do: {:ok, %{}},
        else: {:error, "backfill/2 raised " <> Exception.message(e)}

    e in ArgumentError ->
      {:error, Exception.message(e)}

    e ->
      {:error, "backfill/2 raised " <> Exception.message(e)}
  end

  ## Promotion

  @doc """
  Brings the live tables from `before` to `after_` for `version`, in one
  transaction: `{:ok, summary}` or `{:error, why}`, with nothing changed.
  """
  @spec run(Version.t(), Schema.tables(), Schema.tables(), boolean()) ::
          {:ok, map()} | {:error, String.t()}
  def run(%Version{} = version, before, after_, backfill?) do
    plan = Schema.plan(before, after_)
    prefix = DB.prefix()

    with {:ok, module} <- backfill_module(version, backfill?) do
      try do
        result =
          Postgrex.transaction(
            @pool,
            fn conn ->
              Postgrex.query!(conn, "SET LOCAL statement_timeout = 120000", [])
              for sql <- Schema.ddl(prefix, after_), do: Postgrex.query!(conn, sql, [])
              filled = if module, do: fill(conn, module, before, after_), else: %{}

              for {t, c} <- plan.required do
                q = Store.query!(t, where: [{c, nil}])

                case DB.count(conn, after_, q) do
                  0 ->
                    :ok

                  n ->
                    DBConnection.rollback(conn, "#{n} rows of #{t} have no #{c} after backfill/2")
                end
              end

              for sql <- Schema.finish_ddl(prefix, plan), do: Postgrex.query!(conn, sql, [])
              filled
            end,
            timeout: 600_000
          )

        case result do
          {:ok, filled} ->
            {:ok,
             %{
               dropped_tables: plan.drop_tables,
               dropped_columns: plan.drop_columns,
               dropped_indexes: plan.drop_indexes,
               required: plan.required,
               filled: filled
             }}

          {:error, why} when is_binary(why) ->
            {:error, why}

          {:error, other} ->
            {:error, "the schema change did not apply: #{inspect(other, limit: 10)}"}
        end
      rescue
        e in Postgrex.Error ->
          {:error, "the schema change did not apply: " <> Exception.message(e)}
      after
        if module do
          :code.purge(module)
          :code.delete(module)
        end
      end
    end
  end

  defp backfill_module(_version, false), do: {:ok, nil}

  defp backfill_module(%Version{} = version, true) do
    name = Module.concat([Theseus.Backfill, "B#{System.unique_integer([:positive])}"])

    case Theseus.Validator.load_candidate(version, name) do
      {:ok, _beam, _warnings} -> {:ok, name}
      {:error, why} -> {:error, "backfill/2 did not compile: #{inspect(why, limit: 10)}"}
    end
  end

  # Every row of every table that existed, a batch at a time: the values
  # backfill/2 returns are written. A row it refuses stops everything.
  defp fill(conn, module, before, after_) do
    for {t, _} <- Enum.sort(before), Map.has_key?(after_, t), into: %{} do
      {t, fill_table(conn, module, t, after_, 0, 0)}
    end
  catch
    {:backfill_error, why} -> DBConnection.rollback(conn, why)
  end

  defp fill_table(conn, module, table, tables, offset, n) do
    rows = DB.all(conn, tables, Store.query!(table, limit: @batch, offset: offset))

    ops =
      for row <- rows,
          {:ok, c} <- [checked(changes(module, table, row, tables), table, row)],
          c != %{},
          do: {:update, table, row.id, c}

    :ok = DB.apply_writes(conn, tables, ops)
    n = n + length(ops)

    if length(rows) == @batch,
      do: fill_table(conn, module, table, tables, offset + @batch, n),
      else: n
  end

  defp checked({:error, why}, table, row),
    do: throw({:backfill_error, "backfill/2 on #{table} #{row.id}: #{why}"})

  defp checked(ok, _table, _row), do: ok

  ## Rollbacks

  @doc """
  Why `module` may not go back to version `target` on `branch`: it
  mentions a table or column a migration dropped there, or nil.
  """
  @spec rollback_refusal(module(), String.t(), String.t()) :: String.t() | nil
  def rollback_refusal(module, target, branch) do
    with [_ | _] = gone <- gone(branch),
         {:ok, %Version{ast: ast}} when ast != nil <- Ledger.version(module, target) do
      atoms = Schema.mentions(ast)

      hits =
        for name <- gone, mentioned?(name, atoms) do
          case name do
            {t, c} -> "#{t}.#{c}"
            t -> "table #{t}"
          end
        end

      if hits != [],
        do:
          "version #{Version.short(target)} of #{inspect(module)} mentions #{Enum.join(hits, ", ")}, which a schema change dropped with its data; propose a version that does not"
    else
      _ -> nil
    end
  end

  defp mentioned?({t, c}, atoms), do: t in atoms and c in atoms
  defp mentioned?(t, atoms), do: t in atoms

  # Tables and columns dropped on the branch that its schema does not
  # declare again.
  defp gone(branch) do
    current =
      case DB.schema_units(branch) |> Enum.map(&elem(&1, 1)) |> Schema.merge() do
        {:ok, tables} -> tables
        _ -> %{}
      end

    dropped =
      Ledger.memo({:schema_dropped, branch}, fn ->
        for %Event{body: {:schema_migrated, _, summary}, branch: ^branch} <- Ledger.events(),
            name <- summary.dropped_tables ++ summary.dropped_columns,
            do: name
      end)

    dropped
    |> Enum.uniq()
    |> Enum.reject(fn
      {t, c} -> current[t] != nil and Map.has_key?(current[t].columns, c)
      t -> Map.has_key?(current, t)
    end)
  end
end
