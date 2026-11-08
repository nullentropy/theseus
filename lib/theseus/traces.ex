defmodule Theseus.Traces do
  @moduledoc """
  Recorded invocations of units. Callers write straight into ETS; this
  process only owns the tables.

  Every call goes into a ring buffer for its unit and function (config
  `:trace_buffer` calls each), so a function called often, such as one a
  scheduled tick calls every minute, cannot push the other functions'
  calls out.
  Failing calls are also kept in a second table, one entry per distinct call
  (config `:failing_traces` per unit, oldest dropped first), so they outlive
  the ring buffer. Together they are the replay set.

  Traces are redacted (`Theseus.Redact`) before they are stored anywhere.
  This process also writes them to the encrypted trace file
  (`Theseus.TraceFile`) and loads them back at startup. The file is
  rewritten with only the retained traces at startup and as it grows.
  """

  use GenServer

  alias Theseus.{Redact, Trace, TraceFile}

  @buffer :theseus_traces
  @seq :theseus_trace_seq
  @failing :theseus_failing_traces

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(Trace.t()) :: :ok
  def record(%Trace{} = trace) do
    trace = redact(trace)
    insert(trace)
    GenServer.cast(__MODULE__, {:persist, trace})
  end

  defp insert(%Trace{unit: unit, fun: fun} = trace) do
    n = :ets.update_counter(@seq, {unit, fun}, 1, {{unit, fun}, 0})
    :ets.insert(@buffer, {{unit, fun, rem(n, capacity())}, trace.id, trace})
    if match?({:error, _, _}, trace.result), do: keep_failing(trace)
    :ok
  end

  defp redact(%Trace{args: args, result: result} = trace) do
    result =
      case result do
        {:ok, value} -> {:ok, Redact.term(value)}
        {:error, error, stacktrace} -> {:error, Redact.term(error), Redact.term(stacktrace)}
      end

    %{trace | args: Redact.term(args), result: result}
  end

  @doc "Traces for a unit from the ring buffer, newest first. Takes `:limit`."
  @spec list(module(), keyword()) :: [Trace.t()]
  def list(unit, opts \\ []) do
    @buffer
    |> :ets.match_object({{unit, :_, :_}, :_, :_})
    |> newest_first(Keyword.get(opts, :limit, capacity()))
  end

  @doc "Retained failing calls for a unit, newest first, tagged `:failing`."
  @spec failing(module()) :: [Trace.t()]
  def failing(unit) do
    @failing
    |> :ets.match_object({{unit, :_}, :_, :_})
    |> newest_first(nil)
  end

  @doc """
  Every retained call to a unit, once per distinct `{fun, args}`, newest
  first: the ring buffer plus the retained failing calls.
  """
  #
  # On the leader, the set takes in the calls each follower recorded too
  # (see Theseus.Leader). A server unit's calls all run on the leader, so
  # its ordered set is the leader's own. A follower that does not answer
  # adds nothing.
  @spec replay_set(module(), keyword()) :: [Trace.t()]
  def replay_set(unit, opts \\ []) do
    followers = Theseus.Leader.followers()

    if followers == [] or Keyword.get(opts, :in_order, false),
      do: local_replay_set(unit, opts),
      else: gather(unit, opts, followers)
  end

  defp gather(unit, opts, followers) do
    remote =
      followers
      |> :erpc.multicall(__MODULE__, :local_replay_set, [unit, opts], 10_000)
      |> Enum.flat_map(fn
        {:ok, traces} -> traces
        _ -> []
      end)

    (local_replay_set(unit, opts) ++ remote)
    |> Enum.uniq_by(&{&1.fun, &1.args})
    |> Enum.take(Keyword.get(opts, :limit, 1_000))
  end

  @doc false
  # This node's own replay set.
  def local_replay_set(unit, opts \\ []) do
    if Keyword.get(opts, :in_order, false) do
      # Every call, oldest first: a server unit's results depend on the
      # calls before them.
      (list(unit) ++ failing(unit))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.id)
      |> Enum.take(-Keyword.get(opts, :limit, 1_000))
    else
      (list(unit) ++ failing(unit))
      |> Enum.sort_by(& &1.id, :desc)
      |> Enum.uniq_by(&{&1.fun, &1.args})
      |> Enum.take(Keyword.get(opts, :limit, 1_000))
    end
  end

  @spec count(module()) :: non_neg_integer()
  def count(unit), do: :ets.select_count(@buffer, [{{{unit, :_, :_}, :_, :_}, [], [true]}])

  @spec clear(module()) :: :ok
  def clear(unit) do
    :ets.match_delete(@buffer, {{unit, :_, :_}, :_, :_})
    :ets.match_delete(@failing, {{unit, :_}, :_, :_})
    GenServer.call(__MODULE__, :compact)
  end

  defp keep_failing(%Trace{unit: unit} = trace) do
    trace = %{trace | tags: Enum.uniq([:failing | trace.tags])}
    :ets.insert(@failing, {{unit, :erlang.phash2({trace.fun, trace.args})}, trace.id, trace})
    limit = :persistent_term.get({__MODULE__, :failing_capacity})

    if :ets.select_count(@failing, [{{{unit, :_}, :_, :_}, [], [true]}]) > limit do
      oldest =
        :ets.select(@failing, [{{{unit, :"$1"}, :"$2", :_}, [], [{{:"$2", :"$1"}}]}])
        |> Enum.min()

      :ets.delete(@failing, {unit, elem(oldest, 1)})
    end
  end

  defp newest_first(rows, limit) do
    traces = rows |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.map(&elem(&1, 2))
    if limit, do: Enum.take(traces, limit), else: traces
  end

  defp capacity, do: :persistent_term.get({__MODULE__, :capacity})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    capacity =
      Keyword.get_lazy(opts, :capacity, fn -> Application.fetch_env!(:theseus, :trace_buffer) end)

    failing =
      Keyword.get_lazy(opts, :failing_capacity, fn ->
        Application.get_env(:theseus, :failing_traces, 200)
      end)

    :persistent_term.put({__MODULE__, :capacity}, capacity)
    :persistent_term.put({__MODULE__, :failing_capacity}, failing)

    for table <- [@buffer, @failing] do
      :ets.new(table, [
        :set,
        :named_table,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    :ets.new(@seq, [:set, :named_table, :public, write_concurrency: true])

    file =
      if Application.get_env(:theseus, :trace_file, true) do
        {file, traces} = TraceFile.open(TraceFile.adopt(), TraceFile.key())

        for t <- traces,
            do: insert(%{t | id: System.unique_integer([:positive, :monotonic])})

        TraceFile.rewrite(file, retained())
      end

    {:ok, %{file: file, since_compact: 0}}
  end

  @impl true
  def handle_cast({:persist, _trace}, %{file: nil} = state), do: {:noreply, state}

  def handle_cast({:persist, trace}, state) do
    :ok = TraceFile.append(state.file, trace)
    state = %{state | since_compact: state.since_compact + 1}

    if state.since_compact >= max(1_000, 3 * :ets.info(@buffer, :size)),
      do: {:noreply, compact(state)},
      else: {:noreply, state}
  end

  @impl true
  def handle_call(:compact, _from, state), do: {:reply, :ok, compact(state)}

  @impl true
  def terminate(_reason, %{file: file}) when file != nil, do: TraceFile.close(file)
  def terminate(_reason, _state), do: :ok

  defp compact(%{file: nil} = state), do: state

  defp compact(state),
    do: %{state | file: TraceFile.rewrite(state.file, retained()), since_compact: 0}

  # Every trace still held in memory, oldest first, once each.
  defp retained do
    (:ets.select(@buffer, [{{:_, :_, :"$1"}, [], [:"$1"]}]) ++
       :ets.select(@failing, [{{:_, :_, :"$1"}, [], [:"$1"]}]))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&%{&1 | tags: List.delete(&1.tags, :failing)})
  end
end
