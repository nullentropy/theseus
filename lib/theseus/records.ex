defmodule Theseus.Records do
  @moduledoc """
  Where the engine keeps its own records that change while it runs: the
  outbox, connections, API clients and server units' state. Each is a log of
  Erlang terms, encrypted with AES-256-GCM under the state key as in
  `Theseus.SealedLog`, read in order at boot and rewritten in full now and
  then.

  With a database (`THESEUS_DATABASE_URL`), the records are kept in the
  app's Postgres schema, in the table `_theseus_records` (`log`, `seq`,
  `data`), which no schema unit can declare or read. Without one, each log
  is a file next to the ledger, as before. Config `:records` (`:auto`, the
  default; `:files`; `:database`) chooses.

  The first time a log is opened in the database while its file still holds
  records, they are copied in and the file is renamed to
  `<file>.imported-to-database`. A database that cannot be reached at boot
  is waited for, every 5 seconds, so the engine never keeps some records in
  files and the rest in the database. Rows written with another key are
  set aside under `<log>.unreadable-<time>` and the log starts empty, as a
  file would.
  """

  require Logger

  alias Theseus.SealedLog

  @table "_theseus_records"
  @wait_ms 5_000

  @type t :: SealedLog.t() | %{db: String.t(), key: binary(), key_id: binary()}

  @doc """
  Opens the log `name`, kept in the file at `path` when there is no
  database. Returns the handle and the terms, oldest first.
  """
  @spec open(String.t(), Path.t(), binary(), <<_::64>>, keyword()) :: {t(), [term()]}
  def open(name, path, key, magic, opts \\ []) do
    if database?() do
      key_id = SealedLog.key_id(key)
      wait()
      ensure_table()
      handle = %{db: name, key: key, key_id: key_id}

      case read(handle) do
        {:ok, []} -> {handle, import_file(handle, path, magic)}
        {:ok, terms} -> {handle, terms}
      end
    else
      SealedLog.open(path, key, magic, opts)
    end
  end

  @doc "Adds a term."
  @spec append(t(), term()) :: :ok
  def append(%{db: name} = h, term) do
    query!("INSERT INTO #{table()} (log, data) VALUES ($1, $2)", [name, seal(h, term)])
    :ok
  end

  def append(file, term), do: SealedLog.append(file, term)

  @doc "Replaces the log's terms."
  @spec rewrite(t(), [term()]) :: t()
  def rewrite(%{db: name} = h, terms) do
    {:ok, _} =
      Postgrex.transaction(pool(), fn conn ->
        Postgrex.query!(conn, "DELETE FROM #{table()} WHERE log = $1", [name])

        for chunk <- Enum.chunk_every(terms, 500), chunk != [] do
          rows = Enum.with_index(chunk, fn _t, i -> "($1, $#{i + 2})" end) |> Enum.join(", ")
          values = [name | Enum.map(chunk, &seal(h, &1))]
          Postgrex.query!(conn, "INSERT INTO #{table()} (log, data) VALUES #{rows}", values)
        end
      end)

    h
  end

  def rewrite(file, terms), do: SealedLog.rewrite(file, terms)

  @doc "Closes the log."
  @spec close(t()) :: :ok
  def close(%{db: _}), do: :ok
  def close(file), do: SealedLog.close(file)

  @doc "Whether the records are kept in the database."
  @spec database?() :: boolean()
  def database? do
    case Application.get_env(:theseus, :records, :auto) do
      :files -> false
      :database -> true
      _ -> Theseus.Store.DB.configured?() and not Theseus.Store.DB.preview?()
    end
  end

  defp read(%{db: name, key: key, key_id: key_id}) do
    rows = query!("SELECT data FROM #{table()} WHERE log = $1 ORDER BY seq", [name]).rows

    decoded = for [data] <- rows, do: SealedLog.unseal(data, key, key_id)

    if Enum.any?(decoded, &(&1 == :error)) do
      aside = "#{name}.unreadable-#{System.os_time(:millisecond)}"

      Logger.error(
        "the #{name} records were written with another key; set aside as #{aside}, starting empty. " <>
          "Start again with the right key and rename them back to keep their contents."
      )

      query!("UPDATE #{table()} SET log = $2 WHERE log = $1", [name, aside])
      {:ok, []}
    else
      {:ok, for({:ok, term} <- decoded, do: term)}
    end
  end

  # Records still in the file move into the database once.
  defp import_file(handle, path, magic) do
    with true <- File.exists?(path),
         {file, terms} <- SealedLog.open(path, handle.key, magic),
         :ok <- SealedLog.close(file),
         [_ | _] <- terms do
      rewrite(handle, terms)
      File.rename!(path, path <> ".imported-to-database")
      Logger.info("moved #{length(terms)} #{handle.db} records from #{path} into the database")
      terms
    else
      _ -> []
    end
  end

  defp wait do
    case Postgrex.query(pool(), "SELECT 1", []) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "waiting for the database to keep the engine's records (#{Exception.message(error)})"
        )

        Process.sleep(@wait_ms)
        wait()
    end
  end

  defp ensure_table do
    query!(
      "CREATE SCHEMA IF NOT EXISTS #{Theseus.Schema.quote_name(Theseus.Store.DB.prefix())}",
      []
    )

    query!(
      "CREATE TABLE IF NOT EXISTS #{table()} (log text NOT NULL, seq bigserial PRIMARY KEY, data bytea NOT NULL)",
      []
    )

    query!("CREATE INDEX IF NOT EXISTS \"_theseus_records_log\" ON #{table()} (log, seq)", [])
  end

  defp seal(%{key: key, key_id: key_id}, term), do: SealedLog.seal(term, key, key_id)

  defp table,
    do:
      Theseus.Schema.quote_name(Theseus.Store.DB.prefix()) <>
        "." <> Theseus.Schema.quote_name(@table)

  defp query!(sql, params), do: Postgrex.query!(pool(), sql, params)

  defp pool, do: Theseus.Store.Pool
end
