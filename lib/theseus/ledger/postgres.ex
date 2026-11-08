defmodule Theseus.Ledger.Postgres do
  @moduledoc """
  The ledger in Postgres, when the engine keeps its records there
  (`Theseus.Records.database?/0`): the table `_theseus_ledger` (`pos`,
  `payload`) in the app's schema holds the same records as the file, in
  order, one row each.

  One node writes it: the leader, which holds a Postgres advisory lock on
  its own connection for as long as it runs, and writes every record
  through that connection, and its node name in `_theseus_leader`. Another
  node follows it, reading rows as they are written (see
  `Theseus.Leader`), or waits for the lock as a standby, without opening
  anything else. Either becomes the leader when the lock is free. When the
  leader's connection goes, so do its lock and its means to write, and the
  ledger process stops (see `Theseus.Ledger`).

  The first time the table is empty while the ledger file holds records,
  they are copied in, in order, and the file is renamed to
  `<file>.imported-to-database`.
  """

  require Logger

  @table "_theseus_ledger"
  @leader "_theseus_leader"
  @archive "_theseus_ledger_archive"
  @pool Theseus.Ledger.Pool

  @type t :: %{conn: pid(), prefix: String.t()}

  @doc """
  Waits for the database, then for the lock, unless this node can follow
  (see `Theseus.Leader`): the leader opens the table, copying the file at
  `path` in if the table is empty. Returns the role, the handle and the
  next position.

  Every running node also holds a shared lock, so compaction can tell that
  one runs.
  """
  @spec open(Path.t()) :: {:leader | :follower, t(), non_neg_integer()}
  def open(path) do
    prefix = Theseus.Store.DB.prefix()
    conn = connect()
    Postgrex.query!(conn, "SELECT pg_advisory_lock_shared(hashtext($1))", [nodes_lock(prefix)])
    role = lock(conn, prefix)

    Postgrex.query!(conn, "CREATE SCHEMA IF NOT EXISTS #{q(prefix)}", [])

    Postgrex.query!(
      conn,
      "CREATE TABLE IF NOT EXISTS #{table(prefix)} (pos bigint PRIMARY KEY, payload bytea NOT NULL)",
      []
    )

    Postgrex.query!(
      conn,
      "CREATE TABLE IF NOT EXISTS #{q(prefix)}.#{q(@leader)} (id int PRIMARY KEY, node text NOT NULL, at timestamptz NOT NULL)",
      []
    )

    {:ok, _} =
      Postgrex.start_link(
        Theseus.Store.DB.connection_opts() ++ [name: @pool, pool_size: 2, backoff_type: :exp]
      )

    handle = %{conn: conn, prefix: prefix}

    if role == :leader do
      Postgrex.query!(
        conn,
        "INSERT INTO #{q(prefix)}.#{q(@leader)} (id, node, at) VALUES (1, $1, now()) " <>
          "ON CONFLICT (id) DO UPDATE SET node = $1, at = now()",
        [Atom.to_string(Kernel.node())]
      )

      import_file(handle, path)
    end

    %{rows: [[n]]} =
      Postgrex.query!(conn, "SELECT coalesce(max(pos) + 1, 0) FROM #{table(prefix)}", [])

    {role, handle, n}
  end

  @doc "Takes the lock if it is free. A follower asks, to take over."
  @spec try_lead(t()) :: boolean()
  def try_lead(%{conn: conn, prefix: prefix}) do
    %{rows: [[got]]} =
      Postgrex.query!(conn, "SELECT pg_try_advisory_lock(hashtext($1))", [lock_name(prefix)])

    got
  end

  @doc "The leader's node, as it wrote it when it took the lock, or nil."
  @spec leader_node(t()) :: node() | nil
  def leader_node(%{conn: conn, prefix: prefix}) do
    case Postgrex.query!(conn, "SELECT node FROM #{q(prefix)}.#{q(@leader)} WHERE id = 1", []) do
      %{rows: [[name]]} -> String.to_atom(name)
      _ -> nil
    end
  end

  @doc "The rows from `pos` on, in order: `[{pos, payload}]`."
  @spec rows_from(t(), non_neg_integer()) :: [{non_neg_integer(), binary()}]
  def rows_from(%{conn: conn, prefix: prefix}, pos) do
    Postgrex.query!(
      conn,
      "SELECT pos, payload FROM #{table(prefix)} WHERE pos >= $1 ORDER BY pos",
      [pos],
      timeout: :infinity
    ).rows
    |> Enum.map(fn [pos, payload] -> {pos, payload} end)
  end

  # The lock connection stops, and does not reconnect, when it is lost:
  # a reconnected session would no longer hold the lock.
  defp connect do
    case Postgrex.start_link(
           Theseus.Store.DB.connection_opts() ++ [pool_size: 1, backoff_type: :stop]
         ) do
      {:ok, conn} ->
        case Postgrex.query(conn, "SELECT 1", []) do
          {:ok, _} ->
            conn

          {:error, error} ->
            GenServer.stop(conn)
            wait("the database (#{Exception.message(error)})")
            connect()
        end

      {:error, error} ->
        wait("the database (#{inspect(error)})")
        connect()
    end
  end

  defp lock(conn, prefix, said? \\ false) do
    case Postgrex.query!(conn, "SELECT pg_try_advisory_lock(hashtext($1))", [lock_name(prefix)]) do
      %{rows: [[true]]} ->
        Logger.info("this node holds the ledger for #{prefix}")
        :leader

      %{rows: [[false]]} ->
        if Theseus.Leader.can_follow?() do
          Logger.info("another node holds the ledger for #{prefix}; following it")
          :follower
        else
          unless said? do
            Theseus.Leader.became(:standby)
            Logger.info("another node holds the ledger for #{prefix}; standing by until it stops")
          end

          Process.sleep(Application.get_env(:theseus, :ledger_standby_ms, 2_000))
          lock(conn, prefix, true)
        end
    end
  end

  defp wait(what) do
    Logger.info("waiting for #{what}")
    Process.sleep(Application.get_env(:theseus, :ledger_standby_ms, 2_000))
  end

  defp lock_name(prefix), do: "theseus_ledger:" <> prefix
  defp nodes_lock(prefix), do: "theseus_nodes:" <> prefix

  @doc "Calls `fun.(pos, payload)` for each row, in order."
  @spec each(t(), (non_neg_integer(), binary() -> any())) :: :ok
  def each(%{conn: conn, prefix: prefix}, fun) do
    {:ok, :ok} =
      Postgrex.transaction(
        conn,
        fn c ->
          c
          |> Postgrex.stream("SELECT pos, payload FROM #{table(prefix)} ORDER BY pos", [],
            max_rows: 500
          )
          |> Enum.each(fn %{rows: rows} -> for [pos, payload] <- rows, do: fun.(pos, payload) end)

          :ok
        end,
        timeout: :infinity
      )

    :ok
  end

  @doc "Writes a record at `pos`, through the connection that holds the lock."
  @spec append(t(), non_neg_integer(), binary()) :: :ok
  def append(%{conn: conn, prefix: prefix}, pos, payload) do
    Postgrex.query!(
      conn,
      "WITH row AS (INSERT INTO #{table(prefix)} (pos, payload) VALUES ($1, $2) RETURNING pos) " <>
        "SELECT pg_notify($3, row.pos::text) FROM row",
      [pos, payload, channel(prefix)]
    )

    :ok
  end

  @doc """
  On a follower: listens for the leader's writes. This process then gets
  `{:notification, _, _, _, pos}` for each row as it is committed.
  """
  @spec listen(t()) :: :ok
  def listen(%{prefix: prefix}) do
    {:ok, pid} =
      Postgrex.Notifications.start_link(
        Theseus.Store.DB.connection_opts() ++ [auto_reconnect: true]
      )

    {:ok, _ref} = Postgrex.Notifications.listen(pid, channel(prefix))
    :ok
  end

  # A channel name is at most 63 bytes, so a long schema name is hashed.
  defp channel(prefix) do
    hash = Base.encode16(:crypto.hash(:sha256, prefix), case: :lower)
    "theseus_ledger_" <> binary_part(hash, 0, 32)
  end

  @doc "The payload at `pos`, for beams read on demand, or nil."
  @spec read(String.t(), non_neg_integer()) :: binary() | nil
  def read(prefix, pos) do
    case Postgrex.query(@pool, "SELECT payload FROM #{table(prefix)} WHERE pos = $1", [pos]) do
      {:ok, %{rows: [[payload]]}} -> payload
      _ -> nil
    end
  end

  defp import_file(%{conn: conn, prefix: prefix}, path) do
    with %{rows: [[0]]} <- Postgrex.query!(conn, "SELECT count(*) FROM #{table(prefix)}", []),
         true <- File.exists?(path),
         {:ok, payloads} when payloads != [] <- Theseus.Ledger.payloads(path) do
      {:ok, _} =
        Postgrex.transaction(
          conn,
          fn c ->
            payloads
            |> Enum.with_index()
            |> Enum.chunk_every(200)
            |> Enum.each(fn chunk ->
              marks =
                Enum.map_join(Enum.with_index(chunk), ", ", fn {_, i} ->
                  "($#{2 * i + 1}, $#{2 * i + 2})"
                end)

              params = Enum.flat_map(chunk, fn {payload, pos} -> [pos, payload] end)

              Postgrex.query!(
                c,
                "INSERT INTO #{table(prefix)} (pos, payload) VALUES #{marks}",
                params
              )
            end)
          end,
          timeout: :infinity
        )

      File.rename!(path, path <> ".imported-to-database")
      Logger.info("moved #{length(payloads)} ledger records from #{path} into the database")
    else
      _ -> :ok
    end
  end

  ## Compaction (see Theseus.Compact)

  @doc """
  The ledger's lock for compaction with no node running: `{:ok, handle}`,
  or `{:error, why}` when the database cannot be reached or a node runs
  the ledger.
  """
  @spec standalone() :: {:ok, t()} | {:error, String.t()}
  def standalone do
    prefix = Theseus.Store.DB.prefix()

    case Postgrex.start_link(
           Theseus.Store.DB.connection_opts() ++ [pool_size: 1, backoff_type: :stop]
         ) do
      {:ok, conn} ->
        case Postgrex.query(
               conn,
               "SELECT pg_try_advisory_lock(hashtext($1)), pg_try_advisory_lock(hashtext($2))",
               [lock_name(prefix), nodes_lock(prefix)]
             ) do
          {:ok, %{rows: [[true, true]]}} ->
            {:ok, %{conn: conn, prefix: prefix}}

          other ->
            GenServer.stop(conn)

            case other do
              {:ok, _} ->
                {:error, running(prefix)}

              {:error, error} ->
                {:error, "could not reach the database: #{inspect(error)}"}
            end
        end

      {:error, error} ->
        {:error, "could not reach the database: #{inspect(error)}"}
    end
  end

  defp running(prefix),
    do:
      "a node is running this app's ledger in #{prefix}. The app compacts it itself: " <>
        "run Theseus.compact() on that node, or stop it first."

  @doc "Lets the lock go."
  @spec release(t()) :: :ok
  def release(%{conn: conn}), do: GenServer.stop(conn)

  @doc "The payloads' total size in bytes."
  @spec size(t()) :: non_neg_integer()
  def size(%{conn: conn, prefix: prefix}) do
    %{rows: [[n]]} =
      Postgrex.query!(
        conn,
        "SELECT coalesce(sum(octet_length(payload)), 0)::bigint FROM #{table(prefix)}",
        []
      )

    n
  end

  @doc "Deletes what the archive got before `cutoff`. Returns how many rows went."
  @spec prune_archive(t(), DateTime.t()) :: non_neg_integer()
  def prune_archive(%{conn: conn, prefix: prefix}, cutoff) do
    case Postgrex.query(
           conn,
           "DELETE FROM #{q(prefix)}.#{q(@archive)} WHERE archived_at < $1",
           [cutoff]
         ) do
      {:ok, %{num_rows: n}} -> n
      # No compaction has archived anything yet.
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} -> 0
    end
  end

  @doc """
  Carries out a compaction planned by `Theseus.Compact.plan/4`, in one
  transaction: the rows it changes or drops are copied to
  `_theseus_ledger_archive`, the changed rows get their new payloads at the
  same positions, the dropped beams' rows go, and the compaction event is
  added. All of it is kept only if `plan.check` accepts the ledger as it
  reads back.
  """
  @spec apply_compaction(t(), map()) :: :ok | {:error, String.t()}
  def apply_compaction(%{conn: conn, prefix: prefix}, plan) do
    archive = "#{q(prefix)}.#{q(@archive)}"
    {event_pos, event_payload} = plan.event
    changed = for {pos, _old, new} <- plan.changed, do: {pos, new}
    dropped = for {pos, _old, _key} <- plan.dropped, do: pos

    result =
      Postgrex.transaction(
        conn,
        fn c ->
          Postgrex.query!(
            c,
            "CREATE TABLE IF NOT EXISTS #{archive} (pos bigint NOT NULL, payload bytea NOT NULL, archived_at timestamptz NOT NULL)",
            []
          )

          Postgrex.query!(
            c,
            "INSERT INTO #{archive} (pos, payload, archived_at) " <>
              "SELECT pos, payload, now() FROM #{table(prefix)} WHERE pos = ANY($1)",
            [Enum.map(changed, &elem(&1, 0)) ++ dropped]
          )

          for chunk <- Enum.chunk_every(changed, 200) do
            Postgrex.query!(
              c,
              "UPDATE #{table(prefix)} AS t SET payload = v.payload " <>
                "FROM unnest($1::bigint[], $2::bytea[]) AS v(pos, payload) WHERE t.pos = v.pos",
              [Enum.map(chunk, &elem(&1, 0)), Enum.map(chunk, &elem(&1, 1))]
            )
          end

          Postgrex.query!(c, "DELETE FROM #{table(prefix)} WHERE pos = ANY($1)", [dropped])

          Postgrex.query!(
            c,
            "WITH row AS (INSERT INTO #{table(prefix)} (pos, payload) VALUES ($1, $2) RETURNING pos) " <>
              "SELECT pg_notify($3, row.pos::text) FROM row",
            [event_pos, event_payload, channel(prefix)]
          )

          back =
            Postgrex.query!(c, "SELECT payload FROM #{table(prefix)} ORDER BY pos", [],
              timeout: :infinity
            ).rows
            |> Enum.map(&hd/1)

          case plan.check.(Theseus.Ledger.records_from_payloads(back)) do
            :ok -> :ok
            {:error, why} -> DBConnection.rollback(c, why)
          end
        end,
        timeout: :infinity
      )

    case result do
      {:ok, :ok} -> :ok
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, other} -> {:error, "the compacted ledger was not written: #{inspect(other)}"}
    end
  end

  defp table(prefix), do: "#{q(prefix)}.#{q(@table)}"
  defp q(name), do: Theseus.Schema.quote_name(name)
end
