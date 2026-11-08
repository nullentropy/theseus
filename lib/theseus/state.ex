defmodule Theseus.State do
  @moduledoc """
  Keeps server units' state across restarts, in an encrypted state file
  next to the ledger (`<ledger>.state`, config `:state_path`; turn it off
  with `state_file: false`). The file is a `Theseus.SealedLog` (magic
  `THESEUSS`, the state key from `Theseus.Keys`) of snapshots
  `{:state, module, version, state, at}`; the latest per unit wins, and the
  file is rewritten with only those at boot and as it grows. With a
  database, the snapshots are kept there instead (`Theseus.Records`).

  Only what changed is written. Whether the state changed, and how, is
  worked out inside the unit's process, against the state it last saved
  (kept in that process, sharing its memory), so an unchanged state costs
  nothing and a changed one leaves the process only as its changes. A save
  is `{:state_ops, module, version, ops, at}`: values put, map keys
  dropped, and items put in front of a list, by path (`{:k, key}` into a
  map, `{:e, index}` into a tuple). Maps are compared key by key, tuples of
  one size element by element, and a list that grew at the front gives
  only its new items; anything else changed is put whole at its place. A
  new version, or a process that saved nothing yet, writes the whole
  state. A unit's deltas are folded into one whole
  snapshot once they outgrow it, and at boot.

  When saved: shortly after any call to a server unit through
  `Theseus.call/3` (debounced), every 2 seconds for state that changes on
  its own, and when Theseus stops. A snapshot is written only when the state
  or the unit's version changed. Every write is flushed to disk, so a crash
  of the whole VM loses at most the last moments of changes.

  When restored: when the engine starts a server unit (`Theseus.Servers`):
  at boot, when a change creates one, when a switch brings one in, and when
  it restarts after a crash. A snapshot from another version of the unit is
  migrated with the current version's `code_change(old_version, state,
  nil)`, as in an upgrade. A snapshot that cannot be migrated is kept aside
  in `<state file>.unrestored`, and the unit starts fresh.

  State must be plain data. A state holding pids, ports, references or
  functions is not saved, and the review page says so.
  """

  use GenServer
  require Logger

  alias Theseus.{Keys, Records, Registry, SealedLog}

  @magic "THESEUSS"
  @table __MODULE__
  @states Module.concat(__MODULE__, States)
  @saved {__MODULE__, :saved}
  @debounce_ms 50
  @sweep_ms 2_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The state file's path."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:theseus, :state_path) ||
      Application.fetch_env!(:theseus, :ledger_path) <> ".state"
  end

  @doc "Notes that a server unit may have changed its state."
  @spec touch(module()) :: :ok
  def touch(module) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:touch, module})
    end
  end

  @doc """
  Puts a freshly started server unit process on its saved state. Runs in
  the caller, so it is safe to call while the state process is busy.
  Returns whether a snapshot was restored, or `:not_running` before the
  state process has loaded the file.
  """
  @spec restore(module(), pid()) :: boolean() | :not_running
  def restore(module, pid) do
    if :ets.whereis(@table) == :undefined do
      :not_running
    else
      case current(module) do
        {nil, _, _} -> false
        {version, value, at} -> put_state(module, pid, %{version: version, state: value, at: at})
      end
    end
  end

  @doc "Saves every server unit's state now."
  @spec flush() :: :ok
  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush, 30_000)
    end
  end

  @doc """
  What is saved, per unit: `%{version, bytes, at}`, or `%{error: reason}`
  for a unit whose state could not be saved. `bytes` is the size of its
  last whole snapshot and the deltas since.
  """
  @spec saved() :: %{module() => map()}
  def saved do
    if :ets.whereis(@table) == :undefined do
      %{}
    else
      for {module, meta} <- :ets.tab2list(@table), into: %{} do
        {module, Map.take(meta, [:version, :bytes, :at, :error])}
      end
    end
  end

  # Server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(@states, [:ordered_set, :named_table, :public, read_concurrency: true])

    file =
      if Application.get_env(:theseus, :state_file, true) do
        {file, records} = Records.open("state", path(), Keys.state(), @magic, sync: true)

        for {module, {version, state, at}} <- fold(records),
            do: put_full(module, version, state, at)

        Records.rewrite(file, current_records())
      end

    # Servers started before the file was read get their state now.
    for {module, pid} <- Theseus.Servers.unrestored() do
      restore(module, pid)
      Theseus.Servers.restored(module, pid)
    end

    Process.send_after(self(), :sweep, @sweep_ms)

    {:ok, %{file: file, dirty: MapSet.new(), timer: nil, written: 0, deltas: %{}}}
  end

  # The latest whole state of each unit, with its deltas applied.
  defp fold(records) do
    Enum.reduce(records, %{}, fn
      {:state, module, version, state, at}, acc ->
        Map.put(acc, module, {version, state, at})

      {:state_ops, module, version, ops, at}, acc ->
        case acc do
          %{^module => {^version, state, _}} ->
            Map.put(acc, module, {version, apply_ops(state, ops), at})

          # Changes without the snapshot they follow: nothing to apply them to.
          _ ->
            acc
        end

      {:state_delta, module, version, puts, drops, at}, acc ->
        case acc do
          %{^module => {^version, state, _}} when is_map(state) ->
            Map.put(acc, module, {version, apply_delta(state, puts, drops), at})

          _ ->
            acc
        end

      _other, acc ->
        acc
    end)
  end

  @impl true
  def handle_cast({:touch, module}, state) do
    timer = state.timer || Process.send_after(self(), :save_dirty, @debounce_ms)
    {:noreply, %{state | dirty: MapSet.put(state.dirty, module), timer: timer}}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, save_all(state)}

  @impl true
  def handle_info(:save_dirty, state) do
    state = Enum.reduce(state.dirty, state, &save(&2, &1))
    {:noreply, %{state | dirty: MapSet.new(), timer: nil}}
  end

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, save_all(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = save_all(state)
    if state.file, do: Records.close(state.file)
    :ok
  end

  defp save_all(state) do
    Theseus.Servers.running()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reduce(state, &save(&2, &1))
  end

  defp save(%{file: nil} = state, _module), do: state

  defp save(state, module) do
    do_save(state, module)
  rescue
    e ->
      note_error(module, "saving failed: " <> Exception.message(e))
      state
  end

  defp do_save(state, module) do
    with {:ok, pid} <- Theseus.Servers.pid(module),
         {:ok, %{kind: :server, current_version: version}} <- Registry.fetch(module),
         {:ok, change} <- changes(pid, version),
         {:ok, %{current_version: ^version}} <- Registry.fetch(module) do
      write(state, module, pid, version, change)
    else
      {:error, reason} ->
        note_error(module, reason)
        state

      _ ->
        state
    end
  end

  defp write(state, _module, _pid, _version, :same), do: state

  defp write(state, module, pid, version, change) do
    at = DateTime.utc_now()

    try do
      case change do
        {:full, value} ->
          :ok = Records.append(state.file, {:state, module, version, value, at})
          bytes = put_full(module, version, value, at)

          compact(%{
            state
            | written: state.written + bytes,
              deltas: Map.delete(state.deltas, module)
          })

        {:delta, ops} ->
          :ok = Records.append(state.file, {:state_ops, module, version, ops, at})
          bytes = put_delta(module, version, ops, at)
          since = Map.get(state.deltas, module, 0) + bytes

          state = %{
            state
            | written: state.written + bytes,
              deltas: Map.put(state.deltas, module, since)
          }

          maybe_whole(state, module, since)
      end
    rescue
      e ->
        # What the process holds as saved no longer matches what is written.
        forget(pid)
        reraise e, __STACKTRACE__
    end
  end

  # Once a unit's deltas outgrow its whole snapshot, one whole snapshot
  # replaces them, so a restore reads little more than the state itself.
  defp maybe_whole(state, module, since) do
    case :ets.lookup(@table, module) do
      [{_, %{full_bytes: full, version: version}}] when since > full ->
        {_, value, at} = current(module)
        :ok = Records.append(state.file, {:state, module, version, value, at})
        bytes = put_full(module, version, value, at)

        compact(%{
          state
          | written: state.written + bytes,
            deltas: Map.delete(state.deltas, module)
        })

      _ ->
        state
    end
  end

  # The file is rewritten with one snapshot a unit once it holds much more
  # than that.
  defp compact(state) do
    live = :ets.foldl(fn {_, meta}, n -> n + Map.get(meta, :bytes, 0) end, 0, @table)

    if state.written > 2 * live + 1_000_000,
      do: %{state | file: Records.rewrite(state.file, current_records()), written: 0, deltas: %{}},
      else: state
  end

  defp current_records do
    for {module, _meta} <- :ets.tab2list(@table),
        {version, value, at} <- [current(module)],
        version != nil,
        do: {:state, module, version, value, at}
  end

  # A unit's saved state: its whole snapshot with the deltas since applied.
  defp current(module) do
    case :ets.match_object(@states, {{module, :_}, :_}) do
      [{{_, 0}, {:full, version, value, at}} | deltas] ->
        Enum.reduce(deltas, {version, value, at}, fn {_, {:delta, ops, at}}, {v, value, _} ->
          {v, apply_ops(value, ops), at}
        end)

      _ ->
        {nil, nil, nil}
    end
  end

  defp put_full(module, version, value, at) do
    bytes = byte_size(:erlang.term_to_binary({version, value}))
    :ets.match_delete(@states, {{module, :_}, :_})
    :ets.insert(@states, {{module, 0}, {:full, version, value, at}})

    :ets.insert(
      @table,
      {module, %{version: version, at: at, bytes: bytes, full_bytes: bytes, seq: 0}}
    )

    bytes
  end

  defp put_delta(module, version, ops, at) do
    bytes = byte_size(:erlang.term_to_binary(ops))
    [{_, meta}] = :ets.lookup(@table, module)
    seq = meta.seq + 1
    :ets.insert(@states, {{module, seq}, {:delta, ops, at}})

    :ets.insert(
      @table,
      {module,
       %{meta | version: version, at: at, bytes: meta.bytes + bytes, seq: seq}
       |> Map.delete(:error)}
    )

    bytes
  end

  defp note_error(module, reason) do
    case :ets.lookup(@table, module) do
      [{_, %{error: ^reason}}] ->
        :ok

      [{_, meta}] ->
        Logger.warning("not saving #{inspect(module)}'s state: #{reason}")
        :ets.insert(@table, {module, Map.put(meta, :error, reason)})

      [] ->
        Logger.warning("not saving #{inspect(module)}'s state: #{reason}")
        :ets.insert(@table, {module, %{error: reason, version: nil, at: nil, bytes: 0, seq: 0}})
    end
  end

  # How the state changed since the process last saved it, worked out in
  # the process: `:same`, `{:delta, ops}` or `{:full, state}`. The
  # process then holds the state as saved.
  defp changes(pid, version) do
    me = self()
    ref = make_ref()

    :sys.replace_state(
      pid,
      fn current ->
        send(me, {ref, compare(Process.get(@saved), version, current)})
        Process.put(@saved, {version, current})
        current
      end,
      1_000
    )

    receive do
      {^ref, {:error, _} = error} ->
        forget(pid)
        error

      {^ref, change} ->
        {:ok, change}
    after
      0 -> :busy
    end
  catch
    :exit, _ -> :busy
  end

  @doc false
  # In the unit's process. Unchanged parts of the state are the same terms
  # as those saved, so comparing them is quick.
  def compare({version, saved}, version, saved), do: :same

  def compare({version, saved}, version, current) do
    case diff(saved, current, [], []) do
      [{:put, [], _}] ->
        with :ok <- plain(current), do: {:full, current}

      ops ->
        ops = Enum.reverse(ops)

        if Enum.all?(ops, &plain_op?/1),
          do: {:delta, ops},
          else: {:error, "it holds a pid, port, reference or function"}
    end
  end

  def compare(_saved, _version, current) do
    with :ok <- plain(current), do: {:full, current}
  end

  defp plain_op?({:put, _path, v}), do: plain?(v)
  defp plain_op?({:prepend, _path, items}), do: plain?(items)
  defp plain_op?({:drop, _path}), do: true

  # The changes from `old` to `new`, newest first, by path: `{:k, key}` into
  # a map, `{:e, index}` into a tuple. A map is compared key by key, a tuple
  # of the same size element by element, and a list that grew at the front
  # gives only what was put in front. Anything else is put whole.
  defp diff(old, new, path, ops) when is_map(old) and is_map(new) and map_size(old) > 0 do
    # :maps.fold, not Enum: structs such as MapSet enumerate their elements.
    ops =
      :maps.fold(
        fn k, v, ops ->
          case old do
            %{^k => ^v} -> ops
            %{^k => o} -> diff(o, v, [{:k, k} | path], ops)
            _ -> [{:put, Enum.reverse([{:k, k} | path]), v} | ops]
          end
        end,
        ops,
        new
      )

    :maps.fold(
      fn k, _, ops ->
        if Map.has_key?(new, k), do: ops, else: [{:drop, Enum.reverse([{:k, k} | path])} | ops]
      end,
      ops,
      old
    )
  end

  defp diff(old, new, path, ops)
       when is_tuple(old) and is_tuple(new) and tuple_size(old) == tuple_size(new) and
              tuple_size(old) > 0 do
    Enum.reduce(0..(tuple_size(new) - 1), ops, fn i, ops ->
      o = elem(old, i)
      v = elem(new, i)
      if o === v, do: ops, else: diff(o, v, [{:e, i} | path], ops)
    end)
  end

  defp diff(old, new, path, ops) when is_list(old) and is_list(new) and old != [] do
    case grown(old, new) do
      {:ok, items} -> [{:prepend, Enum.reverse(path), items} | ops]
      :no -> [{:put, Enum.reverse(path), new} | ops]
    end
  end

  defp diff(_old, new, path, ops), do: [{:put, Enum.reverse(path), new} | ops]

  # What was put in front of `old` to make `new`, when that is all that
  # changed. The tail is the same term, so the comparison is quick.
  defp grown(old, new) do
    d = length(new) - length(old)

    if d > 0 and Enum.drop(new, d) === old,
      do: {:ok, Enum.take(new, d)},
      else: :no
  rescue
    # An improper list has no length.
    ArgumentError -> :no
  end

  @doc false
  def apply_ops(state, ops) do
    Enum.reduce(ops, state, fn
      {:put, path, v}, s -> change(s, path, fn _ -> v end)
      {:prepend, path, items}, s -> change(s, path, &(items ++ &1))
      {:drop, path}, s -> drop(s, path)
    end)
  end

  defp change(term, [], fun), do: fun.(term)
  defp change(term, [step | rest], fun), do: set(term, step, change(get(term, step), rest, fun))

  defp drop(map, [{:k, k}]), do: Map.delete(map, k)
  defp drop(term, [step | rest]), do: set(term, step, drop(get(term, step), rest))

  defp get(map, {:k, k}), do: Map.get(map, k)
  defp get(tuple, {:e, i}), do: elem(tuple, i)
  defp set(map, {:k, k}, v), do: Map.put(map, k, v)
  defp set(tuple, {:e, i}, v), do: put_elem(tuple, i, v)

  @doc false
  # Deltas written as `{:state_delta, ...}`: map keys only, by plain paths.
  def apply_delta(state, puts, drops) do
    ops =
      for({path, v} <- puts, do: {:put, Enum.map(path, &{:k, &1}), v}) ++
        for(path <- drops, do: {:drop, Enum.map(path, &{:k, &1})})

    apply_ops(state, ops)
  end

  # The process no longer holds what was written as saved: the next save
  # writes the whole state.
  defp forget(pid) do
    :sys.replace_state(
      pid,
      fn s ->
        Process.delete(@saved)
        s
      end,
      1_000
    )
  catch
    :exit, _ -> :ok
  end

  # Only plain data survives a restart.
  defp plain(value) do
    if plain?(value), do: :ok, else: {:error, "it holds a pid, port, reference or function"}
  end

  @doc "Whether a term is plain data: no pids, ports, references or functions."
  @spec plain?(term()) :: boolean()
  def plain?(v) when is_pid(v) or is_port(v) or is_reference(v) or is_function(v), do: false
  def plain?(v) when is_list(v), do: plain_list?(v)
  def plain?(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.all?(&plain?/1)
  # Map.to_list, not Enum: structs such as MapSet enumerate their elements.
  def plain?(%{} = v),
    do: v |> Map.to_list() |> Enum.all?(fn {k, x} -> plain?(k) and plain?(x) end)

  def plain?(_v), do: true

  defp plain_list?([h | t]), do: plain?(h) and plain_list?(t)
  defp plain_list?([]), do: true
  defp plain_list?(tail), do: plain?(tail)

  defp put_state(module, pid, %{version: saved, state: value} = snapshot) do
    current =
      case Registry.fetch(module) do
        {:ok, %{current_version: v}} -> v
        _ -> nil
      end

    migrated =
      if saved == current do
        {:ok, value}
      else
        try do
          case module.code_change(saved, value, nil) do
            {:ok, new} -> {:ok, new}
            other -> {:error, "code_change/3 returned #{inspect(other, limit: 5)}"}
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason, limit: 5)}"}
        end
      end

    case migrated do
      {:ok, new} ->
        # The process holds what is saved, so its next save is a delta; a
        # migrated state is saved whole under the current version.
        :sys.replace_state(pid, fn _ ->
          if saved == current,
            do: Process.put(@saved, {current, new}),
            else: Process.delete(@saved)

          new
        end)

        Logger.info("restored #{inspect(module)}'s state")
        # A migrated state is saved again under the current version.
        if saved != current, do: touch(module)
        true

      {:error, reason} ->
        set_aside(module, snapshot)

        Logger.error(
          "could not migrate #{inspect(module)}'s saved state from version " <>
            "#{String.slice(saved, 0, 12)}: #{reason}. It is kept in #{path()}.unrestored; " <>
            "the unit starts fresh."
        )

        :ets.delete(@table, module)
        :ets.match_delete(@states, {{module, :_}, :_})
        false
    end
  end

  defp set_aside(module, %{version: v, state: s, at: at}) do
    {file, _} = SealedLog.open(path() <> ".unrestored", Keys.state(), @magic, sync: true)
    :ok = SealedLog.append(file, {:state, module, v, s, at})
    SealedLog.close(file)
  end
end
