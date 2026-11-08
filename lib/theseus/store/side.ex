defmodule Theseus.Store.Side do
  @moduledoc """
  One side of a comparison, "before" or "after", for replaying recorded
  calls (see `Theseus.Validator.Behaviour`). Each side has its own data,
  and the writes a call returns are applied to it, so later calls see them,
  as each side has its own copy of the server units' state.

  With a database, a side is one transaction on the snapshot the live node
  exported for the validation, rolled back when the side stops: the
  proposed code reads the real data and keeps nothing. Without a database,
  or when it cannot be reached, the side holds rows in memory, empty at
  the start.

  A side never writes the app's tables. Its writes go to temporary tables
  of its own, and its reads see the app's rows with those writes laid over
  them (`DB.overlay!/2`), so it takes no row lock and no live request waits
  for it. The tables are read as the branch and the change have them: a
  column the app's table lacks reads as its default or empty, and a table
  the app lacks starts empty.

  Recorded calls already happened, so their rows are often in the data
  (ids are deterministic): an insert whose row exists leaves it as it is,
  and an update or delete that matches no row is noted, not an error. Both
  sides see the same data, so the comparison holds.
  """

  alias Theseus.Store
  alias Theseus.Store.DB

  @snapshot_id ~r/^[0-9A-Fa-f-]+$/

  @doc """
  Starts a side. Options: `snapshot` (`%{id, connection}` from
  `DB.export_snapshot/0`, or nil) and `tables`. Returns the side and what
  it runs on, `:snapshot` or `:memory`.
  """
  @spec start(keyword()) :: {pid(), :snapshot | :memory}
  def start(opts) do
    parent = self()
    pid = spawn_link(fn -> init(parent, opts[:snapshot], opts[:tables]) end)

    receive do
      {:side_ready, ^pid, data} -> {pid, data}
    after
      30_000 -> raise "the comparison's data did not open in time"
    end
  end

  @doc """
  Runs `fun` on a side and applies the writes its `{:ok, value}` returns.
  Returns `{result, status}`: `:ok`, `{:conflict, why}` when a write
  matched no row, or `{:refused, why}` when the tables refuse a write.
  """
  @spec run(pid(), (-> term())) ::
          {term(), :ok | {:conflict, String.t()} | {:refused, String.t()}}
  def run(side, fun) do
    ref = make_ref()
    send(side, {:run, self(), ref, fun})

    receive do
      {^ref, reply} -> reply
    end
  end

  @doc "Stops a side, rolling back whatever it wrote."
  @spec stop(pid()) :: :ok
  def stop(side) do
    send(side, {:stop, self()})

    receive do
      {:stopped, ^side} -> :ok
    after
      10_000 -> Process.exit(side, :kill)
    end

    :ok
  end

  defp init(parent, snapshot, tables) do
    Process.flag(:trap_exit, true)

    case open(snapshot) do
      {:ok, conn, id} ->
        send(parent, {:side_ready, self(), :snapshot})

        Postgrex.transaction(
          conn,
          fn c ->
            Postgrex.query!(c, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
            Postgrex.query!(c, "SET TRANSACTION SNAPSHOT '#{id}'", [])
            # The side writes to tables of its own, laid over the app's,
            # which it only reads: no live request waits for it.
            DB.overlay!(c, tables || %{})

            loop({:pg, c, tables})
            DBConnection.rollback(c, :side_done)
          end,
          timeout: :infinity
        )

      :memory ->
        send(parent, {:side_ready, self(), :memory})
        loop({:memory, %{}, tables})
    end
  end

  defp open(%{id: id, connection: connection, prefix: prefix}) do
    # The sandbox has no app config: the tables' schema comes with the snapshot.
    Application.put_env(:theseus, :store, schema: prefix)

    with true <- Regex.match?(@snapshot_id, id),
         {:ok, _} <- Application.ensure_all_started(:postgrex),
         :ok <- quiet(),
         {:ok, conn} <-
           Postgrex.start_link(
             connection ++
               [pool_size: 1, types: Theseus.Store.PostgresTypes, backoff_type: :stop]
           ),
         {:ok, _} <- Postgrex.query(conn, "SELECT 1", []) do
      {:ok, conn, id}
    else
      _ -> :memory
    end
  end

  defp open(_none), do: :memory

  # Starting Postgrex starts Logger, which turns logging back on; on the
  # sandbox nothing may write to the node's output (see `Theseus.Sandbox`).
  defp quiet do
    if :persistent_term.get({Theseus.Call, :sandbox}, false),
      do: :logger.set_primary_config(:level, :none)

    :ok
  end

  defp loop(state) do
    receive do
      {:run, from, ref, fun} ->
        {reply, state} = run_in(state, fun)
        send(from, {ref, reply})
        loop(state)

      {:stop, from} ->
        send(from, {:stopped, self()})
        :ok

      {:EXIT, _pid, _reason} ->
        loop(state)
    end
  end

  # One savepoint around the call and its writes: a query that fails, or a
  # write the tables refuse, leaves the transaction usable for the next call.
  defp run_in({:pg, conn, tables} = state, fun) do
    Store.put_context({:pg, conn, tables})
    Store.next_call()
    Postgrex.query!(conn, "SAVEPOINT side_call", [])
    result = fun.()

    status =
      try do
        case apply_pg(conn, tables, writes(result)) do
          :ok ->
            Postgrex.query!(conn, "RELEASE SAVEPOINT side_call", [])
            :ok

          {:conflict, why} ->
            Postgrex.query!(conn, "ROLLBACK TO SAVEPOINT side_call", [])
            {:conflict, why}
        end
      rescue
        e in [ArgumentError, Postgrex.Error] ->
          Postgrex.query!(conn, "ROLLBACK TO SAVEPOINT side_call", [])
          {:refused, Exception.message(e)}
      end

    {{result, status}, state}
  end

  defp run_in({:memory, rows, tables}, fun) do
    Store.put_context({:memory, rows})
    Store.next_call()
    result = fun.()

    {status, rows} =
      case writes(result) do
        [] ->
          {:ok, rows}

        ops ->
          try do
            case Store.memory_apply(rows, tables, ops, :replay) do
              {:ok, rows} -> {:ok, rows}
              {:conflict, why} -> {{:conflict, why}, rows}
            end
          rescue
            e in ArgumentError -> {{:refused, Exception.message(e)}, rows}
          end
      end

    {{result, status}, {:memory, rows, tables}}
  end

  defp writes({:ok, value}), do: value |> Store.take_writes() |> elem(0)
  defp writes(_result), do: []

  # A failed read aborts the transaction until the savepoint is rolled back,
  # so a call without writes still checks the transaction.
  defp apply_pg(conn, _tables, []) do
    Postgrex.query!(conn, "SELECT 1", [])
    :ok
  end

  defp apply_pg(conn, tables, ops), do: DB.apply_writes(conn, tables, ops, :replay)
end
