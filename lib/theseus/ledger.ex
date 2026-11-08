defmodule Theseus.Ledger do
  @moduledoc """
  The application: one append-only file holding every unit, version and
  change. The running program is a fold over it.

  The file starts with the header `THESEUS1`. Each record is
  `<<size::32, crc32::32, payload::binary-size(size)>>`, where the payload is
  `term_to_binary` of `{:event, %Theseus.Event{}}` or
  `{:blob, {module, hash}, beam}`. A version's beam is written as a blob
  before its `version_recorded` event.

  A version's code (`source` and `ast`) is written once: a later record
  holding the same version of the same module, with the same code, stores
  `:earlier` in both fields, and reading fills them in from the first. A
  version is usually proposed and then recorded, so this halves what most
  versions cost on disk.

  When the engine keeps its records in Postgres (`Theseus.Records`), the
  ledger is there too, one row per record, and only the node holding its
  lock writes it (`Theseus.Ledger.Postgres`). Another node follows it,
  reading the rows as they come and sending its writes to the leader (see
  `Theseus.Leader`), or waits as a standby; either takes over when the
  lock frees.

  Writes go through this process. Event and version reads come straight from
  ETS; beams are read from the file on demand.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias Theseus.{Event, Version}

  @magic "THESEUS1"
  @events :theseus_ledger_events
  @versions :theseus_ledger_versions
  @blobs :theseus_ledger_blobs
  # Indexes, so reads about one unit cost what they return, not the history:
  # {unit, seq} for each event about a unit, and {{module, seq}, hash} for
  # each recorded version.
  @unit_events :theseus_ledger_unit_events
  @unit_versions :theseus_ledger_unit_versions
  @memo :theseus_ledger_memo
  # {{module, hash}, digest of its code} for each version whose code the
  # file holds, so a later record can point to it.
  @code :theseus_ledger_code
  @write_timeout 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Writes

  @doc """
  Appends an event. `opts` takes `:actor` (required), `:unit` and `:branch`
  (default: the live branch).
  """
  @spec append(tuple(), keyword()) :: {:ok, Event.t()}
  def append(body, opts) when is_tuple(body) do
    actor = Keyword.fetch!(opts, :actor)
    branch = Keyword.get_lazy(opts, :branch, &Theseus.Branches.live/0)
    by = Keyword.get_lazy(opts, :by, &Theseus.Team.by/0)
    call({:append, body, actor, Keyword.get(opts, :unit), branch, by})
  end

  @doc """
  Writes a version's beam and records the version, unless the ledger already
  has it. The version must carry its beam. `opts` takes `:actor` (required),
  `:unit` (default: the version's module) and `:branch`.
  """
  @spec put_version(Version.t(), keyword()) :: {:ok, :recorded | :known}
  def put_version(%Version{beam: beam} = version, opts) when is_binary(beam) do
    actor = Keyword.fetch!(opts, :actor)
    branch = Keyword.get_lazy(opts, :branch, &Theseus.Branches.live/0)

    call({:put_version, version, actor, Keyword.get(opts, :unit, version.unit), branch})
  end

  # A follower's writes go to the leader, and this node reads them back
  # before answering, so the caller sees what it wrote.
  # Writes wait while the ledger compacts.
  defp call(message) do
    if Theseus.Leader.follower?() do
      reply = GenServer.call(Theseus.Leader.name(__MODULE__), message, @write_timeout)
      catch_up()
      reply
    else
      GenServer.call(__MODULE__, message, @write_timeout)
    end
  end

  @doc """
  Compacts the running ledger (see `Theseus.Compact`), on the leader. The
  ledger takes no writes meanwhile. Options as `Theseus.Compact.run/2`.
  """
  @spec compact(keyword()) :: {:ok, map()} | {:error, String.t()}
  def compact(opts), do: call({:compact, opts})

  @doc """
  On a follower: reads the rows the leader has written since the last
  read, and loads what changed (`Theseus.Loader.follow/0`). Elsewhere: :ok.
  """
  @spec catch_up() :: :ok
  def catch_up do
    if Theseus.Leader.follower?() do
      :ok = GenServer.call(__MODULE__, :catch_up)
      Theseus.Loader.follow()
    else
      :ok
    end
  end

  ## Reads

  @doc "All events in order."
  @spec events() :: [Event.t()]
  def events, do: :ets.select(@events, [{{:_, :"$1"}, [], [:"$1"]}])

  @doc "The last `n` events, oldest first."
  @spec recent(non_neg_integer()) :: [Event.t()]
  def recent(n), do: recent(:ets.last(@events), n, [])

  defp recent(:"$end_of_table", _n, acc), do: acc
  defp recent(_seq, 0, acc), do: acc

  defp recent(seq, n, acc) do
    [{^seq, event}] = :ets.lookup(@events, seq)
    recent(:ets.prev(@events, seq), n - 1, [event | acc])
  end

  @doc "Events for one unit in order. `limit: n` keeps the last n."
  @spec events_for(module(), keyword()) :: [Event.t()]
  def events_for(unit, opts \\ []) do
    seqs = :ets.select(@unit_events, [{{{unit, :"$1"}}, [], [:"$1"]}])

    seqs =
      case Keyword.get(opts, :limit) do
        nil -> seqs
        n -> Enum.take(seqs, -n)
      end

    for seq <- seqs, [{_, event}] <- [:ets.lookup(@events, seq)], do: event
  end

  @doc """
  The hashes of every recorded version of a module, oldest first. A version
  recorded again after compaction removed its code is listed once, where it
  was last recorded.
  """
  @spec version_hashes(module()) :: [String.t()]
  def version_hashes(module) do
    @unit_versions
    |> :ets.select([{{{module, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.reverse()
    |> Enum.uniq()
    |> Enum.reverse()
  end

  @doc "Every recorded version of a module, oldest first, without beams (see version_hashes/1)."
  @spec versions_for(module()) :: [Version.t()]
  def versions_for(module) do
    for hash <- version_hashes(module),
        [{_, version}] <- [:ets.lookup(@versions, {module, hash})],
        do: version
  end

  @doc """
  A value worked out from the events, kept until the next event is
  appended: `fun` runs again only then. For folds over the whole history
  that pages repeat, such as each branch's units, so they cost one fold per
  change to the ledger instead of one per call.
  """
  @spec memo(term(), (-> value)) :: value when value: term()
  def memo(key, fun) do
    seq = last_seq()

    case :ets.lookup(@memo, key) do
      [{^key, ^seq, value}] ->
        value

      _ ->
        # Computed from at least the events up to `seq`; a later append
        # changes the sequence number, so it is never kept past one.
        value = fun.()
        :ets.insert(@memo, {key, seq, value})
        value
    end
  end

  defp last_seq do
    case :ets.last(@events) do
      :"$end_of_table" -> 0
      seq -> seq
    end
  end

  @doc "One version with its beam."
  @spec version(module(), String.t()) :: {:ok, Version.t()} | :error
  def version(module, hash) do
    case :ets.lookup(@versions, {module, hash}) do
      [{_, version}] -> {:ok, %{version | beam: read_beam(module, hash)}}
      [] -> :error
    end
  end

  @doc "The hash of the version that is current for `module` on a branch (default live), or nil."
  @spec current(module(), String.t() | nil) :: String.t() | nil
  def current(module, branch \\ nil),
    do: Theseus.Branches.current(branch || Theseus.Branches.live(), module)

  @doc "Every unit and spec on a branch (default live), with its current version there."
  @spec units(String.t() | nil) :: [Unit.t()]
  def units(branch \\ nil), do: Theseus.Branches.units(branch || Theseus.Branches.live())

  @spec path() :: Path.t()
  def path, do: :persistent_term.get({__MODULE__, :path})

  defp read_beam(module, hash) do
    case :persistent_term.get({__MODULE__, :db}, nil) do
      nil -> read_file_beam(module, hash)
      prefix -> read_db_beam(prefix, module, hash)
    end
  end

  defp read_db_beam(prefix, module, hash) do
    with [{_, {pos, _size}}] <- :ets.lookup(@blobs, {module, hash}),
         payload when is_binary(payload) <- Theseus.Ledger.Postgres.read(prefix, pos),
         {:blob, _key, beam} <- :erlang.binary_to_term(payload) do
      beam
    else
      _ -> nil
    end
  end

  defp read_file_beam(module, hash) do
    with [{_, {offset, size}}] <- :ets.lookup(@blobs, {module, hash}),
         {:ok, fd} <- :file.open(String.to_charlist(path()), [:read, :raw, :binary]) do
      try do
        # A compaction may have just moved the beam; a read that finds
        # another record finds nothing, and the loader compiles again.
        with {:ok, payload} <- :file.pread(fd, offset, size),
             {:blob, {^module, ^hash}, beam} <- :erlang.binary_to_term(payload) do
          beam
        else
          _ -> nil
        end
      rescue
        ArgumentError -> nil
      after
        :file.close(fd)
      end
    else
      _ -> nil
    end
  end

  ## Server

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, fn -> Application.fetch_env!(:theseus, :ledger_path) end)
    File.mkdir_p!(Path.dirname(path))

    # In the database, the node that holds the ledger's lock writes it; the
    # others wait here (see Theseus.Ledger.Postgres).
    if Theseus.Records.database?() do
      Process.flag(:trap_exit, true)
      open_db(path)
    else
      open_file_ledger(path)
    end
  end

  # One instance per ledger file (see Theseus.LedgerLock). Trapping exits
  # lets terminate/2 remove the lock when the app stops.
  defp open_file_ledger(path) do
    case Theseus.LedgerLock.acquire(path) do
      :ok ->
        Process.flag(:trap_exit, true)
        open(path)

      {:error, message} ->
        Logger.error(message)
        {:stop, {:ledger_in_use, message}}
    end
  end

  defp open_db(path) do
    {role, db, next} = Theseus.Ledger.Postgres.open(path)
    Theseus.Leader.became(role)
    :persistent_term.put({__MODULE__, :path}, path)
    :persistent_term.put({__MODULE__, :db}, db.prefix)
    new_tables()

    Process.put({__MODULE__, :code}, %{})

    Theseus.Ledger.Postgres.each(db, fn pos, payload ->
      code = load_record(payload, pos, byte_size(payload), Process.get({__MODULE__, :code}))
      Process.put({__MODULE__, :code}, code)
    end)

    code = Process.delete({__MODULE__, :code})
    heartbeat()

    # The HTTP server stopped when the lock was lost starts again once the
    # engine is back; the supervisor is busy restarting it until then.
    if :persistent_term.get({__MODULE__, :web_stopped}, false) do
      :persistent_term.erase({__MODULE__, :web_stopped})

      spawn(fn ->
        Process.sleep(100)
        wait_for_engine()
        Supervisor.restart_child(Theseus.AppSupervisor, Theseus.App)
      end)
    end

    state = %{db: db, fd: nil, size: next, seq: last_seq()}

    case role do
      :leader ->
        check_compaction()
        {:ok, state}

      # A follower keeps the code read so far, for the rows still to come.
      :follower ->
        Theseus.Leader.join(self())
        :ok = Theseus.Ledger.Postgres.listen(db)
        follow_leader(db)
        send(self(), :follow)
        {:ok, Map.put(state, :code, code)}
    end
  end

  defp follow_leader(db) do
    case Theseus.Ledger.Postgres.leader_node(db) do
      nil ->
        :ok

      leader ->
        if leader not in Node.list() and Node.connect(leader) == true,
          do: Theseus.Shadow.mirror_from(leader)

        Theseus.Leader.following(leader)
    end
  end

  # The leader sends its shadowed units when they change; asking now and
  # then also covers a change made while this node was joining.
  defp refresh_shadows(state) do
    now = System.monotonic_time(:millisecond)
    at = Map.get(state, :shadows_at)

    if (at == nil or now - at >= 5_000) and Theseus.Leader.node() != nil do
      Theseus.Shadow.mirror_from(Theseus.Leader.node())
      Map.put(state, :shadows_at, now)
    else
      state
    end
  end

  defp follow(%{code: code} = state) do
    case Theseus.Ledger.Postgres.rows_from(state.db, state.size) do
      [] ->
        state

      rows ->
        {code, _keys, compacted?} = load_rows(rows, code)
        {last, _} = List.last(rows)
        state = %{state | code: code, size: last + 1, seq: last_seq()}
        # The leader compacted the rows before this one in place.
        state = if compacted?, do: reload_rows(state), else: state
        GenServer.cast(Theseus.Loader, :follow)
        state
    end
  end

  # Loads rows into ETS: `{code, the beams' keys, whether one is a
  # compaction}`.
  defp load_rows(rows, code) do
    Enum.reduce(rows, {code, MapSet.new(), false}, fn {pos, payload}, {code, keys, compacted?} ->
      term = :erlang.binary_to_term(payload)
      code = load_term(term, pos, byte_size(payload), code)

      case term do
        {:blob, key, _} -> {code, MapSet.put(keys, key), compacted?}
        {:event, %Event{body: body}} -> {code, keys, compacted? or compaction?(body)}
      end
    end)
  end

  defp compaction?(body), do: is_tuple(body) and elem(body, 0) == :ledger_compacted

  # After a compaction, every record as it now is. Events and versions are
  # overwritten in place, so a reader always finds one; the beams that went
  # are removed, and the code this ledger holds is worked out again, so a
  # later record never points to code that is gone.
  defp reload_rows(state) do
    fresh()
    rows = Theseus.Ledger.Postgres.rows_from(state.db, 0)
    {code, keys, _} = load_rows(rows, %{})

    for key <- :ets.select(@blobs, [{{:"$1", :_}, [], [:"$1"]}]),
        not MapSet.member?(keys, key),
        do: :ets.delete(@blobs, key)

    {last, _} = List.last(rows)
    state = %{state | size: last + 1, seq: last_seq()}
    if Map.has_key?(state, :code), do: %{state | code: code}, else: state
  end

  defp reload_file(state, gone) do
    fresh()
    size = load(path())
    for key <- gone, do: :ets.delete(@blobs, key)
    %{state | size: size, seq: last_seq()}
  end

  defp fresh do
    :ets.delete_all_objects(@code)
    :ets.delete_all_objects(@memo)
  end

  ## Compaction while running

  defp compact_now(opts, state) do
    {reply, state} = compact_records(opts, state)
    target = if state.db, do: {:db, state.db}, else: {:file, path()}
    {Theseus.Compact.finish(reply, target, opts), state}
  end

  defp compact_records(opts, %{db: nil} = state) do
    path = path()

    with {:ok, rows} <- file_rows(path) do
      case Theseus.Compact.plan(rows, opts, state.size, path) do
        {:none, stats} ->
          {{:ok, stats}, state}

        {:plan, plan} ->
          :ok = :file.close(state.fd)
          result = Theseus.Compact.apply_file(path, plan)
          state = %{state | fd: open_fd(path)}

          case result do
            :ok ->
              state = reload_file(state, for({_, _, key} <- plan.dropped, do: key))
              {{:ok, %{plan.stats | after_bytes: state.size}}, state}

            error ->
              {error, state}
          end
      end
    else
      error -> {error, state}
    end
  end

  defp compact_records(opts, %{db: db} = state) do
    alias Theseus.Ledger.Postgres

    case Theseus.Compact.plan(
           Postgres.rows_from(db, 0),
           opts,
           Postgres.size(db),
           "the database (#{db.prefix})"
         ) do
      {:none, stats} ->
        {{:ok, stats}, state}

      {:plan, plan} ->
        case Postgres.apply_compaction(db, plan) do
          :ok -> {{:ok, %{plan.stats | after_bytes: Postgres.size(db)}}, reload_rows(state)}
          error -> {error, state}
        end
    end
  end

  defp check_compaction do
    minutes = Theseus.Compact.settings()[:check_minutes]
    Process.send_after(self(), :compact_check, round(minutes * 60_000))
  end

  # Over the size, and a quarter larger than the last compaction left it,
  # or than it was when the last check found nothing to do.
  defp compaction_due?(state, settings) do
    bytes = if state.db, do: Theseus.Ledger.Postgres.size(state.db), else: state.size

    last =
      @events
      |> :ets.select([{{:_, %{body: {:ledger_compacted, :"$1"}}}, [], [:"$1"]}])
      |> List.last()

    floor = max(if(last, do: last.after_bytes, else: 0), Map.get(state, :nothing_at, 0))
    {bytes > settings[:above_mb] * 1_048_576 and bytes > floor * 1.25, bytes}
  end

  defp open(path) do
    unless File.exists?(path), do: File.write!(path, @magic)
    :persistent_term.put({__MODULE__, :path}, path)
    :persistent_term.erase({__MODULE__, :db})
    new_tables()
    size = load(path)
    check_compaction()
    {:ok, %{db: nil, fd: open_fd(path), size: size, seq: last_seq()}}
  end

  defp open_fd(path) do
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :append, :raw, :binary])
    fd
  end

  # The engine's last child, once its restart reaches it.
  defp wait_for_engine do
    unless Process.whereis(Theseus.State) do
      Process.sleep(50)
      wait_for_engine()
    end
  end

  defp new_tables do
    :ets.new(@events, [:ordered_set, :named_table, :protected, read_concurrency: true])
    :ets.new(@versions, [:set, :named_table, :protected, read_concurrency: true])
    :ets.new(@blobs, [:set, :named_table, :protected, read_concurrency: true])
    :ets.new(@unit_events, [:ordered_set, :named_table, :protected, read_concurrency: true])
    :ets.new(@unit_versions, [:ordered_set, :named_table, :protected, read_concurrency: true])
    # Written by the processes that read through memo/2.
    :ets.new(@memo, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(@code, [:set, :named_table, :protected])
  end

  @impl true
  def handle_call(:catch_up, _from, %{code: _} = state), do: {:reply, :ok, follow(state)}

  def handle_call({:compact, opts}, _from, state) do
    {reply, state} = compact_now(opts, state)
    {:reply, reply, state}
  end

  def handle_call({:append, body, actor, unit, branch, by}, _from, state) do
    {event, state} = write_event(body, actor, unit, branch, state, by)
    {:reply, {:ok, event}, state}
  end

  def handle_call(
        {:put_version, %Version{unit: module, hash: hash} = version, actor, unit, branch},
        _from,
        state
      ) do
    key = {module, hash}

    # Compaction may have removed a version's beam, or its code too. The
    # beam is written again; a version without code is recorded again.
    recorded? =
      case :ets.lookup(@versions, key) do
        [{_, %Version{ast: ast}}] -> ast != nil
        [] -> false
      end

    if recorded? and :ets.member(@blobs, key) do
      {:reply, {:ok, :known}, state}
    else
      {offset, size, state} = write({:blob, key, version.beam}, state)
      :ets.insert(@blobs, {key, {offset, size}})

      state =
        if recorded? do
          state
        else
          body = {:version_recorded, %{version | beam: nil}}
          {_event, state} = write_event(body, actor, unit, branch, state)
          state
        end

      {:reply, {:ok, :recorded}, state}
    end
  end

  # The session that holds the ledger's lock is checked every second. When
  # it is gone, so is the lock, and another node may take over: this one
  # stops writing at once. Its supervisor starts it again, which waits for
  # the lock as a standby would.
  @impl true
  def handle_info(:heartbeat, %{db: %{conn: conn}} = state) do
    case Postgrex.query(conn, "SELECT 1", []) do
      {:ok, _} ->
        heartbeat()
        {:noreply, state}

      {:error, error} ->
        lost(
          "lost the database session that holds the ledger: #{Exception.message(error)}",
          state
        )
    end
  end

  def handle_info(:compact_check, state) do
    check_compaction()
    settings = Theseus.Compact.settings()
    {due?, bytes} = compaction_due?(state, settings)

    state =
      if settings[:auto] and due? do
        case compact_now(Keyword.take(settings, [:keep, :days]) ++ [actor: :system], state) do
          {{:ok, %{records_changed: 0}}, state} ->
            Map.put(state, :nothing_at, bytes)

          {{:ok, stats}, state} ->
            Logger.info(Theseus.Compact.report(stats))
            state

          {{:error, why}, state} ->
            Logger.error("the ledger was not compacted: #{why}")
            Map.put(state, :nothing_at, bytes)
        end
      else
        state
      end

    {:noreply, state}
  end

  # A follower reads the leader's new rows, and takes over when the lock
  # is free: the engine starts again around a ledger that holds it.
  def handle_info(:follow, %{code: _} = state) do
    if Theseus.Ledger.Postgres.try_lead(state.db) do
      Logger.info("the leader stopped; this node takes over the ledger")
      {:stop, {:shutdown, :taking_over}, state}
    else
      follow_leader(state.db)
      Process.send_after(self(), :follow, Application.get_env(:theseus, :ledger_follow_ms, 500))
      {:noreply, state |> follow() |> refresh_shadows()}
    end
  end

  # The leader wrote a row. Reading every `:ledger_follow_ms` catches any
  # notification missed while listening reconnected.
  def handle_info({:notification, _pid, _ref, _channel, _pos}, %{code: _} = state),
    do: {:noreply, follow(state)}

  def handle_info({:EXIT, conn, reason}, %{db: %{conn: conn}} = state),
    do: lost("lost the database connection that holds the ledger: #{inspect(reason)}", state)

  def handle_info(_msg, state), do: {:noreply, state}

  # Requests stop too: the app's HTTP server is stopped until this node
  # holds the ledger again (open_db/1 starts it). The engine's own processes
  # stop with the ledger, the admin port among them.
  defp lost(message, state) do
    Logger.error(
      message <> "; stopping the app's HTTP server until this node holds the ledger again"
    )

    :persistent_term.put({__MODULE__, :web_stopped}, true)

    if Process.whereis(Theseus.AppSupervisor),
      do: Supervisor.terminate_child(Theseus.AppSupervisor, Theseus.App)

    {:stop, :lost_ledger_lock, state}
  end

  @impl true
  def terminate(_reason, %{db: nil, fd: fd}) do
    :file.close(fd)
    Theseus.LedgerLock.release(path())
  end

  def terminate(_reason, _state), do: :ok

  defp heartbeat,
    do:
      Process.send_after(
        self(),
        :heartbeat,
        Application.get_env(:theseus, :ledger_heartbeat_ms, 1_000)
      )

  defp write_event(body, actor, unit, branch, state, by \\ nil) do
    seq = state.seq + 1

    event = %Event{
      seq: seq,
      id: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false),
      at: DateTime.utc_now(),
      actor: actor,
      unit: unit,
      branch: branch,
      by: by,
      body: body
    }

    {_offset, _size, state} = write({:event, shrink(event, &written?/1)}, state)
    remember(event)
    index({:event, event})
    {event, %{state | seq: seq}}
  end

  # Returns the payload's offset and size, for blob lookups.
  defp write(term, state) do
    # Compressed: sources, syntax trees and reports shrink several times.
    # Reading takes compressed and uncompressed records alike.
    payload = :erlang.term_to_binary(term, [:compressed])
    size = byte_size(payload)

    if state.db do
      :ok = Theseus.Ledger.Postgres.append(state.db, state.size, payload)
      {state.size, size, %{state | size: state.size + 1}}
    else
      :ok = :file.write(state.fd, [<<size::32, :erlang.crc32(payload)::32>>, payload])
      :ok = :file.datasync(state.fd)
      {state.size + 8, size, %{state | size: state.size + 8 + size}}
    end
  end

  defp index({:event, %Event{seq: seq, unit: unit, body: body} = event}) do
    :ets.insert(@events, {seq, event})
    if unit != nil, do: :ets.insert(@unit_events, {{unit, seq}})

    with {:version_recorded, %Version{unit: module, hash: hash} = version} <- body do
      :ets.insert(@versions, {{module, hash}, version})
      :ets.insert(@unit_versions, {{module, seq}, hash})
    end
  end

  # Reads every record into ETS and returns the file's valid size. A torn
  # record at the end (a crash during a write) is cut off with a warning.
  # Damage anywhere else stops the boot: history is never dropped silently.
  defp load(path) do
    case File.read!(path) do
      <<@magic, records::binary>> = bin ->
        case scan(records, byte_size(@magic)) do
          {:ok, size} ->
            size

          {:torn, offset} ->
            Logger.warning(
              "ledger: dropping a torn record at the end of #{path} (#{byte_size(bin) - offset} bytes)"
            )

            {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])
            {:ok, _} = :file.position(fd, offset)
            :ok = :file.truncate(fd)
            :ok = :file.close(fd)
            offset

          {:corrupt, offset} ->
            raise "ledger: corrupt record at byte #{offset} of #{path}"
        end

      _ ->
        raise "#{path} is not a Theseus ledger"
    end
  end

  defp scan(records, offset), do: scan(records, offset, %{})

  defp scan(<<>>, offset, _code), do: {:ok, offset}

  defp scan(<<size::32, crc::32, payload::binary-size(size), rest::binary>>, offset, code) do
    cond do
      :erlang.crc32(payload) == crc ->
        code = load_record(payload, offset + 8, size, code)
        scan(rest, offset + 8 + size, code)

      rest == <<>> ->
        {:torn, offset}

      true ->
        {:corrupt, offset}
    end
  end

  defp scan(_partial, offset, _code), do: {:torn, offset}

  # One record into ETS; a blob's place is where its payload can be read
  # again (a file offset, or a row's position).
  defp load_record(payload, place, size, code),
    do: load_term(:erlang.binary_to_term(payload), place, size, code)

  defp load_term(term, place, size, code) do
    case term do
      {:event, event} ->
        {event, code} = expand(event, code)
        remember(event)
        index({:event, event})
        code

      {:blob, key, _beam} ->
        :ets.insert(@blobs, {key, {place, size}})
        code
    end
  end

  @doc false
  # A ledger file's payloads as `[{n, payload}]`, numbered in order.
  def file_rows(path) do
    with {:ok, records} <- read_raw(path),
         do: {:ok, records |> Enum.map(&elem(&1, 1)) |> Enum.with_index(fn p, i -> {i, p} end)}
  end

  @doc false
  # Adds payloads at the end of a ledger file, creating it if needed.
  def append_file(path, payloads) do
    unless File.exists?(path), do: File.write!(path, @magic)
    {:ok, fd} = :file.open(String.to_charlist(path), [:append, :raw, :binary])

    try do
      for payload <- payloads,
          do:
            :ok =
              :file.write(fd, [<<byte_size(payload)::32, :erlang.crc32(payload)::32>>, payload])

      :ok = :file.sync(fd)
    after
      :file.close(fd)
    end
  end

  @doc false
  # The raw payloads of a ledger file, in order (for moving it into the
  # database).
  def payloads(path) do
    with {:ok, records} <- read_raw(path), do: {:ok, Enum.map(records, &elem(&1, 1))}
  end

  defp read_raw(path) do
    case File.read(path) do
      {:ok, <<@magic, records::binary>>} -> parse(records, byte_size(@magic), [])
      {:ok, _} -> {:error, "#{path} is not a Theseus ledger"}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  ## Code written once

  defp digest(%Version{source: source, ast: ast}), do: :erlang.phash2({source, ast}, 1 <<< 32)

  defp whole?(%Version{source: source, ast: ast}),
    do: is_binary(source) and ast not in [nil, :earlier]

  defp written?(%Version{unit: m, hash: h} = v) do
    whole?(v) and
      case :ets.lookup(@code, {m, h}) do
        [{_, d}] -> d == digest(v)
        [] -> false
      end
  end

  # The versions in a record whose code this file now holds.
  defp remember(term) do
    versions(term, fn %Version{unit: m, hash: h} = v ->
      if whole?(v), do: :ets.insert_new(@code, {{m, h}, digest(v)})
    end)
  end

  @doc false
  # A record with the code of each version `seen?` replaced by `:earlier`.
  def shrink(term, seen?) do
    map_versions(term, fn v ->
      if seen?.(v), do: %{v | source: :earlier, ast: :earlier}, else: v
    end)
  end

  @doc false
  # A record as written, with each `:earlier` filled in from `code`, which
  # holds the code read so far: `{record, code}`.
  def expand(term, code) do
    pointing? = reduce_versions(term, false, fn v, acc -> acc or v.source == :earlier end)

    term =
      if not pointing?,
        do: term,
        else:
          map_versions(term, fn
            %Version{source: :earlier, unit: m, hash: h} = v ->
              case code do
                %{{^m, ^h} => {source, ast}} -> %{v | source: source, ast: ast}
                # Its first copy was removed (compaction keeps such pairs whole).
                _ -> %{v | source: nil, ast: nil}
              end

            v ->
              v
          end)

    code =
      reduce_versions(term, code, fn %Version{unit: m, hash: h} = v, code ->
        if whole?(v), do: Map.put_new(code, {m, h}, {v.source, v.ast}), else: code
      end)

    {term, code}
  end

  defp versions(term, fun), do: reduce_versions(term, nil, fn v, _ -> fun.(v) end)

  defp map_versions(%Version{} = v, fun), do: fun.(v)

  defp map_versions(%_{} = struct, fun) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {k, x} -> {k, map_versions(x, fun)} end)
    |> then(&struct(struct.__struct__, &1))
  end

  defp map_versions(%{} = map, fun), do: Map.new(map, fn {k, x} -> {k, map_versions(x, fun)} end)
  defp map_versions(list, fun) when is_list(list), do: map_list(list, fun)

  defp map_versions(tuple, fun) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&map_versions(&1, fun)) |> List.to_tuple()

  defp map_versions(other, _fun), do: other

  # Improper lists too (iodata in a report).
  defp map_list([h | t], fun), do: [map_versions(h, fun) | map_list(t, fun)]
  defp map_list([], _fun), do: []
  defp map_list(tail, fun), do: map_versions(tail, fun)

  defp reduce_versions(%Version{} = v, acc, fun), do: fun.(v, acc)

  defp reduce_versions(%{} = map, acc, fun),
    do: :maps.fold(fn _k, x, acc -> reduce_versions(x, acc, fun) end, acc, map)

  defp reduce_versions([h | t], acc, fun),
    do: reduce_versions(t, reduce_versions(h, acc, fun), fun)

  defp reduce_versions(tuple, acc, fun) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &reduce_versions(&1, &2, fun))

  defp reduce_versions(_other, acc, _fun), do: acc

  ## Files of a stopped ledger (see Theseus.Compact)

  @doc """
  Reads a ledger file that no running Theseus has open. Returns its records
  in order, each with its stored payload: `{record, payload}`, where a
  record is `{:event, %Event{}}` or `{:blob, {module, hash}, beam}`. A torn
  record at the end is left out, as at boot.
  """
  @spec read_file(Path.t()) :: {:ok, [{tuple(), binary()}]} | {:error, String.t()}
  def read_file(path) do
    case File.read(path) do
      {:ok, <<@magic, records::binary>>} ->
        with {:ok, records} <- parse(records, byte_size(@magic), []),
             do: {:ok, whole(records)}

      {:ok, _} ->
        {:error, "#{path} is not a Theseus ledger"}

      {:error, reason} ->
        {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc false
  # Records as `{record, payload}` from stored payloads, in order, as
  # read_file/1 gives them.
  def records_from_payloads(payloads),
    do: payloads |> Enum.map(&{:erlang.binary_to_term(&1), &1}) |> whole()

  # Each record with the code it points to filled in. A record that pointed
  # to earlier code gets no payload, so it is written again in full terms:
  # the earlier copy may not be kept.
  defp whole(records) do
    {records, _code} =
      Enum.map_reduce(records, %{}, fn
        {{:event, event}, payload}, code ->
          {full, code} = expand(event, code)
          {{{:event, full}, if(full == event, do: payload)}, code}

        blob, code ->
          {blob, code}
      end)

    records
  end

  defp parse(<<size::32, crc::32, payload::binary-size(size), rest::binary>>, offset, acc) do
    cond do
      :erlang.crc32(payload) == crc ->
        parse(rest, offset + 8 + size, [{:erlang.binary_to_term(payload), payload} | acc])

      rest == <<>> ->
        {:ok, Enum.reverse(acc)}

      true ->
        {:error, "corrupt record at byte #{offset}"}
    end
  end

  defp parse(_rest_or_torn, _offset, acc), do: {:ok, Enum.reverse(acc)}

  @doc false
  # The payloads for records, in order: a record's stored payload, or the
  # record encoded, with each version's code written once.
  def encode_records(records) do
    {payloads, _written} =
      Enum.map_reduce(records, MapSet.new(), fn {record, payload}, written ->
        key = fn v -> {v.unit, v.hash, digest(v)} end

        payload =
          payload ||
            record
            |> shrink(&(whole?(&1) and MapSet.member?(written, key.(&1))))
            |> :erlang.term_to_binary([:compressed])

        written =
          reduce_versions(record, written, fn v, w ->
            if whole?(v), do: MapSet.put(w, key.(v)), else: w
          end)

        {payload, written}
      end)

    payloads
  end

  @doc """
  Writes a new ledger file from records. Each is `{record, payload}`, where
  a nil payload means encode the record. Fails if the file exists.
  """
  @spec write_file(Path.t(), [{tuple(), binary() | nil}]) :: :ok
  def write_file(path, records), do: write_payloads(path, encode_records(records))

  @doc false
  # Writes a new ledger file of payloads. Fails if the file exists.
  def write_payloads(path, payloads) do
    {:ok, fd} = :file.open(String.to_charlist(path), [:write, :exclusive, :raw, :binary])

    try do
      :ok = :file.write(fd, @magic)

      for payload <- payloads,
          do:
            :ok =
              :file.write(fd, [<<byte_size(payload)::32, :erlang.crc32(payload)::32>>, payload])

      :ok = :file.sync(fd)
    after
      :file.close(fd)
    end
  end
end
