defmodule Theseus.Seed do
  @moduledoc """
  Made-up data for previews, declared in a seed unit: a pure unit that does
  `use Theseus.Seed` and defines `rows/1`, which takes the time the preview
  starts and returns rows for the app's tables, `%{table => [row]}`.

      defmodule App.Seed do
        use Theseus.Seed

        def rows(now) do
          %{
            people: [
              %{id: "p1", domain: "example.com", email: "ann@example.com", name: "Ann Example", role: "admin"},
              %{id: "p2", domain: "example.com", email: "bob@example.com", name: "Bob Example", role: "member"}
            ],
            activity: [
              %{id: "a1", domain: "example.com", at: DateTime.add(now, -3600), text: "Ann approved Bob's request"}
            ]
          }
        end
      end

  A preview (`Theseus.Previews`) starts with these rows in memory and keeps
  its writes there until it stops, so engineers try their work without
  seeing real people's records. With `previews: [data: :production]` a
  preview reads the app's database instead, in transactions that are always
  rolled back, and seed units are not used.

  Validation runs `rows/1` on the sandbox and checks every row against the
  branch's tables: known tables and columns, values of the right type,
  required columns set, and no id twice. A branch may have several seed
  units; their rows are put together. At most #{5_000} rows in all.
  """

  alias Theseus.{Branches, Ledger, Store}

  @callback rows(DateTime.t()) :: %{atom() => [map()]}

  @max_rows 5_000
  # The time validation passes to rows/1.
  @checked_at ~U[2026-01-01 12:00:00.000000Z]

  defmacro __using__(_opts) do
    quote do
      @behaviour Theseus.Seed
    end
  end

  @doc "Whether a unit's syntax tree is a seed unit's."
  @spec seed_unit?(Macro.t() | nil) :: boolean()
  def seed_unit?(nil), do: false

  def seed_unit?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:Theseus, :Seed]} | _]} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  @doc "The seed units on a branch."
  @spec units(String.t()) :: [module()]
  def units(branch) do
    Ledger.memo({:seed_units, branch}, fn ->
      for u <- Branches.units(branch),
          {:ok, %{ast: ast}} <- [Ledger.version(u.module, u.current_version)],
          seed_unit?(ast),
          do: u.module
    end)
  end

  @doc """
  Checks a seed module's rows against `tables` (nil when the app has none):
  `:ok` or `{:error, why}`. Runs the module's code.
  """
  @spec check(module(), map() | nil) :: :ok | {:error, String.t()}
  def check(module, tables) do
    case rows([module], @checked_at, tables) do
      {:ok, _rows} -> :ok
      {:error, why} -> {:error, why}
    end
  end

  @doc """
  The rows of `modules` at `now`, put together and checked against
  `tables`, as the in-memory store holds them: `{:ok, rows}` or
  `{:error, why}`.
  """
  @spec rows([module()], DateTime.t(), map() | nil) :: {:ok, map()} | {:error, String.t()}
  def rows(modules, now, tables) do
    ops =
      for module <- modules,
          {table, list} <- returned!(module, now),
          row <- list,
          do: {:insert, table, row}

    cond do
      length(ops) > @max_rows ->
        {:error, "the seed units return #{length(ops)} rows; at most #{@max_rows}"}

      ops != [] and tables in [nil, %{}] ->
        {:error, "the seed units return rows, but the app has no tables"}

      true ->
        case Store.memory_apply(%{}, tables, ops, :strict) do
          {:ok, rows} -> {:ok, rows}
          {:conflict, why} -> {:error, why}
        end
    end
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
    e -> {:error, "rows/1 raised: " <> Exception.message(e)}
  end

  defp returned!(module, now) do
    case module.rows(now) do
      %{} = map ->
        Enum.map(map, fn
          {table, list} when is_atom(table) and is_list(list) ->
            if Enum.all?(list, &is_map/1),
              do: {table, list},
              else: raise(ArgumentError, "every row for #{table} must be a map")

          {table, _} ->
            raise ArgumentError,
                  "rows/1 must map each table (an atom) to a list of rows, not #{inspect(table)}"
        end)

      other ->
        raise ArgumentError, "rows/1 must return a map of tables to rows, not #{inspect(other)}"
    end
  end
end
