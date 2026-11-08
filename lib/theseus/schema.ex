defmodule Theseus.Schema do
  @moduledoc """
  An app's tables, declared in schema units (see `Theseus.Store`). A schema
  unit is a pure unit that does `use Theseus.Schema` and defines `tables/0`
  returning a literal map, so the engine reads the schema from the syntax
  tree and never runs schema code:

      defmodule App.Schema do
        use Theseus.Schema

        def tables do
          %{
            activity: %{
              columns: %{
                domain: :text,
                at: :utc_datetime,
                actor: :text,
                detail: {:text, null: true}
              },
              indexes: [[:domain, :at]]
            }
          }
        end
      end

  Every table has a text key column `id`, which need not be listed. Column
  types are `:text`, `:integer`, `:boolean`, `:utc_datetime`, `:map` (JSON,
  with string keys) and `:texts` (a list of text). Columns are required unless declared
  `{type, null: true}`; `{type, default: value}` gives a default. Table and
  column names are lowercase letters, digits and `_`.

  The engine creates tables, columns and indexes when a schema unit is
  registered or promoted on the live branch, and at boot. A change may
  also take things away or make a column required (`plan/2`), with steps
  `Theseus.Store.Migrate` checks and runs:

    * Dropping a table, column or index: allowed once no unit on the
      branch, after the change's group, mentions it. Its data goes when the
      change is approved, and no unit or schema version that mentions it
      can be rolled back to afterwards.
    * Making a column required with no default, or adding one: the schema
      unit defines `backfill/2`, which gets a table and a row and returns
      the values to set, `%{column => value}`, or nil to leave the row as
      it is. It runs over every row when the change is approved, and
      validation runs it over the app's data and shows what it would do.
    * A changed backfill/2 runs again the same way, so a schema change can
      also correct data.
    * A column's type does not change: add a new column, fill it with
      backfill/2, move the units to it, then drop the old one. A rename is
      the same steps.
  """

  @types [:text, :integer, :boolean, :utc_datetime, :map, :texts]
  @name ~r/^[a-z][a-z0-9_]{0,39}$/

  @callback tables() :: map()

  defmacro __using__(_opts) do
    quote do
      @behaviour Theseus.Schema
    end
  end

  @type column :: %{type: atom(), null: boolean(), default: term()}
  @type tables :: %{atom() => %{columns: %{atom() => column()}, indexes: [[atom()]]}}

  @doc "Whether a unit's syntax tree is a schema unit's."
  @spec schema_unit?(Macro.t()) :: boolean()
  def schema_unit?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:Theseus, :Schema]} | _]} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  @doc "The tables a schema unit declares, read from its syntax tree."
  @spec from_ast(Macro.t()) :: {:ok, tables()} | {:error, String.t()}
  def from_ast({:defmodule, _, [_name, [do: body]]}) do
    statements =
      case body do
        {:__block__, _, statements} -> statements
        statement -> [statement]
      end

    bodies =
      for {:def, _, [head, [do: value]]} <- statements, tables_head?(head), do: value

    case bodies do
      [value] ->
        case literal(value) do
          {:ok, term} -> normalize(term)
          :error -> {:error, "tables/0 must return a literal map, with no variables or calls"}
        end

      [] ->
        {:error, "a schema unit defines tables/0"}

      _ ->
        {:error, "tables/0 is defined more than once"}
    end
  end

  def from_ast(_ast), do: {:error, "a schema unit is one defmodule"}

  defp tables_head?({:tables, _, args}) when args in [nil, []], do: true
  defp tables_head?(_head), do: false

  @doc false
  # Only literal data: maps, lists, tuples, atoms, numbers, strings. Also
  # reads services units (Theseus.Services).
  def literal({:%{}, _, pairs}) do
    with {:ok, pairs} <- literal_list(pairs), do: {:ok, Map.new(pairs)}
  end

  def literal({:{}, _, elements}) do
    with {:ok, elements} <- literal_list(elements), do: {:ok, List.to_tuple(elements)}
  end

  def literal({a, b}) do
    with {:ok, a} <- literal(a), {:ok, b} <- literal(b), do: {:ok, {a, b}}
  end

  def literal({:-, _, [n]}) when is_number(n), do: {:ok, -n}
  def literal(list) when is_list(list), do: literal_list(list)

  def literal(value) when is_atom(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  def literal(_ast), do: :error

  defp literal_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case literal(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end)
  end

  @doc "Checks and normalises a `tables/0` value."
  @spec normalize(term()) :: {:ok, tables()} | {:error, String.t()}
  def normalize(tables) when is_map(tables) do
    Enum.reduce_while(tables, {:ok, %{}}, fn {name, table}, {:ok, acc} ->
      case table(name, table) do
        {:ok, table} -> {:cont, {:ok, Map.put(acc, name, table)}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
  end

  def normalize(_tables), do: {:error, "tables/0 returns a map of table names to tables"}

  defp table(name, %{columns: columns} = table) when is_map(columns) do
    with :ok <- name(name, "table"),
         :ok <- only_keys(table, [:columns, :indexes], "table #{name}"),
         {:ok, columns} <- columns(name, columns),
         {:ok, indexes} <- indexes(name, Map.get(table, :indexes, []), columns) do
      {:ok, %{columns: columns, indexes: indexes}}
    end
  end

  defp table(name, _table), do: {:error, "table #{inspect(name)} needs columns: %{name => type}"}

  defp columns(table, columns) do
    columns
    |> Map.put_new(:id, :text)
    |> Enum.reduce_while({:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case column(table, name, spec) do
        {:ok, column} -> {:cont, {:ok, Map.put(acc, name, column)}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
  end

  defp column(table, :id, spec) do
    if spec in [:text, {:text, []}],
      do: {:ok, %{type: :text, null: false, default: nil}},
      else: {:error, "#{table}.id is the key: a required text column"}
  end

  defp column(table, name, type) when is_atom(type), do: column(table, name, {type, []})

  defp column(table, name, {type, opts}) when is_list(opts) do
    cond do
      name(name, "column") != :ok ->
        name(name, "column")

      type not in @types ->
        {:error,
         "#{table}.#{name} has type #{inspect(type)}; types are #{Enum.map_join(@types, ", ", &inspect/1)}"}

      not Keyword.keyword?(opts) or Keyword.keys(opts) -- [:null, :default] != [] ->
        {:error, "#{table}.#{name} takes only null: and default:"}

      Keyword.has_key?(opts, :default) and not type?(type, opts[:default]) ->
        {:error, "#{table}.#{name}'s default is not #{kind(type)}"}

      true ->
        {:ok, %{type: type, null: opts[:null] == true, default: opts[:default]}}
    end
  end

  defp column(table, name, _spec),
    do: {:error, "#{table}.#{name} is a type, or {type, null: true} or {type, default: value}"}

  defp indexes(table, indexes, columns) when is_list(indexes) do
    Enum.reduce_while(indexes, {:ok, []}, fn
      [_ | _] = cols, {:ok, acc} ->
        case Enum.reject(cols, &Map.has_key?(columns, &1)) do
          [] ->
            {:cont, {:ok, acc ++ [cols]}}

          [missing | _] ->
            {:halt, {:error, "an index on #{table} names #{inspect(missing)}, not a column"}}
        end

      _other, _acc ->
        {:halt, {:error, "indexes on #{table} are lists of columns, such as [[:domain, :at]]"}}
    end)
  end

  defp indexes(table, _indexes, _columns),
    do: {:error, "indexes on #{table} are lists of columns, such as [[:domain, :at]]"}

  defp name(name, what) do
    if is_atom(name) and Regex.match?(@name, Atom.to_string(name)),
      do: :ok,
      else: {:error, "#{inspect(name)} is not a #{what} name: lowercase letters, digits and _"}
  end

  defp only_keys(map, keys, what) do
    case Map.keys(map) -- keys do
      [] -> :ok
      [extra | _] -> {:error, "#{what} has #{inspect(extra)}; it takes columns: and indexes:"}
    end
  end

  defp kind(:text), do: "text"
  defp kind(:integer), do: "an integer"
  defp kind(:boolean), do: "a boolean"
  defp kind(:utc_datetime), do: "a UTC DateTime"
  defp kind(:map), do: "a map"
  defp kind(:texts), do: "a list of text"

  @doc "Whether a value fits a column type. nil fits none; nullability is separate."
  @spec type?(atom(), term()) :: boolean()
  def type?(:text, v), do: is_binary(v)
  def type?(:integer, v), do: is_integer(v)
  def type?(:boolean, v), do: is_boolean(v)
  def type?(:utc_datetime, v), do: match?(%DateTime{time_zone: "Etc/UTC"}, v)
  def type?(:map, v), do: is_map(v) and not is_struct(v)
  def type?(:texts, v), do: is_list(v) and Enum.all?(v, &is_binary/1)
  def type?(_type, _v), do: false

  @doc "The tables of several schema units together. A table may be declared once."
  @spec merge([tables()]) :: {:ok, tables()} | {:error, String.t()}
  def merge(list) do
    Enum.reduce_while(list, {:ok, %{}}, fn tables, {:ok, acc} ->
      case Enum.find(Map.keys(tables), &Map.has_key?(acc, &1)) do
        nil -> {:cont, {:ok, Map.merge(acc, tables)}}
        table -> {:halt, {:error, "table #{table} is declared in two schema units"}}
      end
    end)
  end

  @typedoc "What a schema change does beyond adding, from `plan/2`."
  @type plan :: %{
          drop_tables: [atom()],
          drop_columns: [{atom(), atom()}],
          drop_indexes: [{atom(), [atom()]}],
          required: [{atom(), atom()}],
          defaulted: [{atom(), atom(), column()}],
          relaxed: [{atom(), atom()}],
          defaults: [{atom(), atom(), column()}],
          type_changes: [{atom(), atom(), atom(), atom()}]
        }

  @doc """
  What going from `old` to `new` takes away or requires of existing rows:
  tables, columns and indexes dropped, columns that existing rows must be
  given a value for (required with no default, and new or nullable before),
  columns made required that take their default where empty, columns made
  optional, columns whose default changes, and columns whose type changes.
  """
  @spec plan(tables(), tables()) :: plan()
  def plan(old, new) do
    kept = for {t, o} <- Enum.sort(old), n = new[t], n != nil, do: {t, o, n}

    %{
      drop_tables: for({t, _} <- Enum.sort(old), not Map.has_key?(new, t), do: t),
      drop_columns:
        for(
          {t, o, n} <- kept,
          {c, _} <- Enum.sort(o.columns),
          not Map.has_key?(n.columns, c),
          do: {t, c}
        ),
      drop_indexes:
        for({t, o, n} <- kept, cols <- o.indexes, cols not in n.indexes, do: {t, cols}),
      required:
        for(
          {t, o, n} <- kept,
          {c, %{null: false, default: nil} = nc} <- Enum.sort(n.columns),
          oc <- [o.columns[c]],
          oc == nil or (oc.null and oc.type == nc.type),
          do: {t, c}
        ),
      defaulted:
        for(
          {t, c, oc, nc} <- same_type(kept),
          oc.null and not nc.null and nc.default != nil,
          do: {t, c, nc}
        ),
      relaxed: for({t, c, oc, nc} <- same_type(kept), not oc.null and nc.null, do: {t, c}),
      defaults: for({t, c, oc, nc} <- same_type(kept), oc.default != nc.default, do: {t, c, nc}),
      type_changes:
        for(
          {t, o, n} <- kept,
          {c, oc} <- Enum.sort(o.columns),
          nc = n.columns[c],
          nc != nil and nc.type != oc.type,
          do: {t, c, oc.type, nc.type}
        )
    }
  end

  # Columns kept with the same type, old and new.
  defp same_type(kept) do
    for {t, o, n} <- kept,
        {c, oc} <- Enum.sort(o.columns),
        c != :id,
        nc = n.columns[c],
        nc != nil and nc.type == oc.type,
        do: {t, c, oc, nc}
  end

  @doc "Whether a plan only adds."
  @spec additive?(plan()) :: boolean()
  def additive?(plan), do: Enum.all?(Map.values(plan), &(&1 == []))

  @doc """
  The reasons a plan cannot go ahead as one change: type changes, and
  columns to require when the schema unit has no backfill/2.
  """
  @spec refusals(plan(), boolean()) :: [String.t()]
  def refusals(plan, backfill?) do
    for(
      {t, c, from, to} <- plan.type_changes,
      do:
        "it changes #{t}.#{c} from #{from} to #{to}; types do not change: add a new column, fill it with backfill/2, move the units to it, then drop #{t}.#{c}"
    ) ++
      if backfill?,
        do: [],
        else:
          for(
            {t, c} <- plan.required,
            do:
              "it makes #{t}.#{c} required with no default; define backfill/2 in the schema unit to give existing rows a value, such as def backfill(:#{t}, row), do: %{#{c}: ...}"
          )
  end

  @doc "Whether a schema unit's syntax tree defines backfill/2."
  @spec backfill?(Macro.t()) :: boolean()
  def backfill?(ast), do: backfill_defs(ast) != []

  @doc false
  # The clauses of backfill/2, to tell whether a change touched it.
  def backfill_defs({:defmodule, _, [_name, [do: body]]}) do
    statements =
      case body do
        {:__block__, _, statements} -> statements
        statement -> [statement]
      end

    for {:def, _, [head, _]} = node <- statements, backfill_head?(head), do: node
  end

  def backfill_defs(_ast), do: []

  defp backfill_head?({:when, _, [head | _]}), do: backfill_head?(head)
  defp backfill_head?({:backfill, _, [_, _]}), do: true
  defp backfill_head?(_head), do: false

  @doc "Every atom a syntax tree mentions, such as table and column names."
  @spec mentions(Macro.t()) :: MapSet.t(atom())
  def mentions(ast) do
    {_, atoms} =
      Macro.prewalk(ast, MapSet.new(), fn
        # Module names are not table or column names.
        {:__aliases__, _, _}, acc -> {nil, acc}
        atom, acc when is_atom(atom) -> {atom, MapSet.put(acc, atom)}
        node, acc -> {node, acc}
      end)

    atoms
  end

  @doc "What `new` adds to `old`, as sentences for a reviewer."
  @spec describe_changes(tables(), tables()) :: [String.t()]
  def describe_changes(old, new) do
    Enum.flat_map(Enum.sort(new), fn {table, %{columns: columns, indexes: indexes}} ->
      case old[table] do
        nil ->
          [
            "adds table #{table}: " <>
              Enum.map_join(Enum.sort(Map.delete(columns, :id)), ", ", &column_text/1)
          ] ++
            for(cols <- indexes, do: "adds an index on #{table} (#{Enum.join(cols, ", ")})")

        %{columns: before, indexes: before_indexes} ->
          for(
            {name, _} = column <- Enum.sort(columns),
            not Map.has_key?(before, name),
            do: "adds column #{table}.#{column_text(column)}"
          ) ++
            for(
              {name, %{null: false, default: nil}} <- Enum.sort(columns),
              before[name] != nil and before[name].null,
              do: "makes #{table}.#{name} required"
            ) ++
            for(
              {name, %{null: false, default: d} = spec} <- Enum.sort(columns),
              d != nil,
              b = before[name],
              b != nil and b.null and b.type == spec.type,
              do: "makes #{table}.#{name} required, giving empty rows #{inspect(d)}"
            ) ++
            for(
              {name, %{null: true} = spec} <- Enum.sort(columns),
              b = before[name],
              b != nil and not b.null and b.type == spec.type,
              do: "makes #{table}.#{name} optional"
            ) ++
            for(
              {name, spec} <- Enum.sort(columns),
              b = before[name],
              b != nil and b.type == spec.type and b.default != spec.default,
              do:
                if(spec.default == nil,
                  do: "removes the default of #{table}.#{name}",
                  else: "sets the default of #{table}.#{name} to #{inspect(spec.default)}"
                )
            ) ++
            for(
              cols <- indexes,
              cols not in before_indexes,
              do: "adds an index on #{table} (#{Enum.join(cols, ", ")})"
            )
      end
    end)
  end

  @doc "What `new` takes away from `old`, as sentences for a reviewer."
  @spec describe_drops(tables(), tables()) :: [String.t()]
  def describe_drops(old, new) do
    p = plan(old, new)

    for(t <- p.drop_tables, do: "drops table #{t} and every row in it") ++
      for({t, c} <- p.drop_columns, do: "drops column #{t}.#{c} and everything in it") ++
      for(
        {t, cols} <- p.drop_indexes,
        not Enum.any?(p.drop_columns, fn {dt, dc} -> dt == t and dc in cols end),
        t not in p.drop_tables,
        do: "drops the index on #{t} (#{Enum.join(cols, ", ")})"
      )
  end

  defp column_text({name, %{type: type, null: null, default: default}}) do
    extra =
      cond do
        default != nil -> ", default #{inspect(default)}"
        null -> ", may be empty"
        true -> ""
      end

    "#{name} (#{type}#{extra})"
  end

  @doc """
  SQL that brings a Postgres schema up to `tables`, in order. Every
  statement can run again: it creates only what is missing.
  """
  @spec ddl(String.t(), tables()) :: [String.t()]
  def ddl(prefix, tables) do
    ["CREATE SCHEMA IF NOT EXISTS #{quote_name(prefix)}"] ++
      Enum.flat_map(Enum.sort(tables), fn {table, %{columns: columns, indexes: indexes}} ->
        name = "#{quote_name(prefix)}.#{quote_name(table)}"
        columns = Enum.sort(columns)

        defs =
          for {column, spec} <- columns do
            "#{quote_name(column)} #{column_sql(spec)}" <>
              if(column == :id, do: " PRIMARY KEY", else: "")
          end

        # A required column added to a table that has rows starts empty;
        # backfill/2 fills it, then finish_ddl/2 makes it required.
        ["CREATE TABLE IF NOT EXISTS #{name} (#{Enum.join(defs, ", ")})"] ++
          for {column, spec} <- columns, column != :id do
            spec = if spec.default == nil, do: %{spec | null: true}, else: spec

            "ALTER TABLE #{name} ADD COLUMN IF NOT EXISTS #{quote_name(column)} #{column_sql(spec)}"
          end ++
          for cols <- indexes do
            "CREATE INDEX IF NOT EXISTS #{quote_name(index_name(table, cols))} ON #{name} (" <>
              Enum.map_join(cols, ", ", &quote_name/1) <> ")"
          end
      end)
  end

  @doc """
  SQL that ends a migration (`Theseus.Store.Migrate`), after ddl/2 and the
  backfill: defaults set, columns made optional, empty rows given the
  default of a column made required, columns made required, then what the
  plan drops.
  """
  @spec finish_ddl(String.t(), plan()) :: [String.t()]
  def finish_ddl(prefix, plan) do
    q = fn table -> "#{quote_name(prefix)}.#{quote_name(table)}" end
    alter = fn t, c, sql -> "ALTER TABLE #{q.(t)} ALTER COLUMN #{quote_name(c)} #{sql}" end

    for(
      {t, c, spec} <- plan.defaults,
      do:
        alter.(
          t,
          c,
          if(spec.default == nil,
            do: "DROP DEFAULT",
            else: "SET DEFAULT #{literal_sql(spec.type, spec.default)}"
          )
        )
    ) ++
      for({t, c} <- plan.relaxed, do: alter.(t, c, "DROP NOT NULL")) ++
      for(
        {t, c, spec} <- plan.defaulted,
        do:
          "UPDATE #{q.(t)} SET #{quote_name(c)} = #{literal_sql(spec.type, spec.default)} WHERE #{quote_name(c)} IS NULL"
      ) ++
      for(
        {t, c} <- plan.required ++ for({t, c, _} <- plan.defaulted, do: {t, c}),
        do: alter.(t, c, "SET NOT NULL")
      ) ++
      for(
        {t, cols} <- plan.drop_indexes,
        t not in plan.drop_tables,
        do: "DROP INDEX IF EXISTS #{quote_name(prefix)}.#{quote_name(index_name(t, cols))}"
      ) ++
      for(
        {t, c} <- plan.drop_columns,
        do: "ALTER TABLE #{q.(t)} DROP COLUMN IF EXISTS #{quote_name(c)}"
      ) ++
      for(t <- plan.drop_tables, do: "DROP TABLE IF EXISTS #{q.(t)}")
  end

  defp index_name(table, cols), do: "#{table}_#{Enum.join(cols, "_")}_idx" |> String.slice(0, 63)

  defp column_sql(%{type: type, null: null, default: default}) do
    sql_type(type) <>
      if(null, do: "", else: " NOT NULL") <>
      if(default == nil, do: "", else: " DEFAULT #{literal_sql(type, default)}")
  end

  @doc false
  def sql_type(:text), do: "text"
  def sql_type(:integer), do: "bigint"
  def sql_type(:boolean), do: "boolean"
  def sql_type(:utc_datetime), do: "timestamptz"
  def sql_type(:map), do: "jsonb"
  def sql_type(:texts), do: "jsonb"

  @doc false
  def literal_sql(:text, v), do: "'" <> String.replace(v, "'", "''") <> "'"
  def literal_sql(:integer, v), do: Integer.to_string(v)
  def literal_sql(:boolean, v), do: to_string(v)

  def literal_sql(:utc_datetime, v),
    do: "'" <> DateTime.to_iso8601(v) <> "'::timestamptz"

  def literal_sql(type, v) when type in [:map, :texts],
    do: "'" <> String.replace(JSON.encode!(v), "'", "''") <> "'::jsonb"

  @doc false
  def quote_name(name), do: ~s(") <> String.replace(to_string(name), ~s("), ~s("")) <> ~s(")
end
