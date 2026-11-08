defmodule Theseus.Previews do
  @moduledoc """
  Runs a branch that is not live on its own node and port, so people and
  agents can send it requests.

  A preview starts a `:peer` node with the same code, gives it a copy of the
  ledger file and the branch name, and starts the application there with its
  own HTTP port on 127.0.0.1 (reached by the team through the admin port,
  see `Theseus.PreviewProxy`). The preview has no admin port, no trace file,
  no crash repair and no consolidation, and writes only to its copy.
  People sign in to it with dev sign-in.

  Its data is made up by default: the branch's seed units' rows
  (`Theseus.Seed`), kept in memory with the preview's writes until it
  stops, so nobody sees real people's records. With
  `previews: [data: :production]` (`THESEUS_PREVIEW_DATA=production`) and
  a database, it reads the app's data in transactions that are always
  rolled back, so it keeps none of its writes. In each of those
  transactions, the tables whose shape on the branch differs from live are
  read and written through overlays (`Theseus.Store.DB.preview_schema/1`),
  so the branch's code finds the tables it expects and no live table is
  altered or locked.

  A preview follows its branch: every `follow_ms` (config `:previews`,
  default 3 seconds) it is started again, on the same port, when the
  branch's versions changed. A preview stops after `:preview_ms` (default
  30 minutes) unless it is kept (`keep: true`), and when it is stopped or
  its branch is closed. Kept previews are remembered with the engine's
  records (log `previews`) and started again when the engine starts.

  At most `max` previews run at once (config `:previews`, default 4). To
  start another, the one used longest ago stops, kept or not; use is a
  request through the admin port (`touch/1`) or its start.
  """

  use GenServer
  require Logger

  alias Theseus.{Branches, Keys, Ledger, Records}

  @magic "THESEUSP"
  @table :theseus_previews

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The previews file's path, when there is no database."
  def path do
    Application.get_env(:theseus, :previews_path) ||
      Application.fetch_env!(:theseus, :ledger_path) <> ".previews"
  end

  @doc """
  Starts a preview of `branch`, or returns the running one. Options:
  `:port`, and `:keep` to keep it running until it is stopped.
  """
  @spec start(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(branch, opts \\ []), do: GenServer.call(__MODULE__, {:start, branch, opts}, 120_000)

  @doc false
  # A request reached a preview (from Theseus.PreviewProxy).
  def touch(branch), do: GenServer.cast(__MODULE__, {:touch, branch, System.monotonic_time()})

  @doc "Stops a preview, and forgets that it was kept."
  @spec stop(String.t()) :: :ok
  def stop(branch), do: GenServer.call(__MODULE__, {:stop, branch}, 30_000)

  @doc """
  Running previews: branch, url, port, when it started, when it stops (nil
  when kept) and whether it is kept. Read without waiting for a preview
  that is starting.
  """
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.branch)
  rescue
    ArgumentError -> []
  end

  ## Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])

    {log, records} =
      if Application.get_env(:theseus, :previews_file, true),
        do: Records.open("previews", path(), Keys.state(), @magic, sync: true),
        else: {nil, []}

    kept =
      Enum.reduce(records, %{}, fn
        {:kept, branch, :deleted}, acc -> Map.delete(acc, branch)
        {:kept, branch, port}, acc -> Map.put(acc, branch, port)
      end)

    if kept != %{}, do: send(self(), :resume)
    schedule_follow()
    {:ok, %{previews: %{}, kept: kept, log: log}}
  end

  @impl true
  def handle_call({:start, branch, opts}, _from, state) do
    {reply, state} = start_preview(state, branch, opts)
    {:reply, reply, state}
  end

  def handle_call({:stop, branch}, _from, state) do
    state = state |> shut(branch) |> unkeep(branch)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:touch, branch, at}, state) do
    case state.previews[branch] do
      nil -> {:noreply, state}
      _ -> {:noreply, put_in(state.previews[branch][:used], at)}
    end
  end

  @impl true
  def handle_info({:expire, branch}, state), do: {:noreply, shut(state, branch)}

  # Kept previews, after the engine starts.
  def handle_info(:resume, state) do
    state =
      Enum.reduce(state.kept, state, fn {branch, port}, state ->
        if Branches.exists?(branch) and not Branches.closed?(branch) do
          case start_preview(state, branch, keep: true, port: port, any_port: true) do
            {{:ok, _}, state} ->
              state

            {{:error, reason}, state} ->
              Logger.warning("kept preview of #{branch} did not start: #{inspect(reason)}")
              state
          end
        else
          unkeep(state, branch)
        end
      end)

    {:noreply, state}
  end

  # A preview whose branch changed starts again on the same port, so its
  # address stays the same. One whose branch is gone or closed stops.
  def handle_info(:follow, state) do
    state =
      Enum.reduce(Map.keys(state.previews), state, fn branch, state ->
        p = state.previews[branch]

        cond do
          not Branches.exists?(branch) or Branches.closed?(branch) ->
            state |> shut(branch) |> unkeep(branch)

          p.versions != versions(branch) ->
            Logger.info("preview of #{branch}: the branch changed, starting it again")
            restart(state, branch, p)

          true ->
            state
        end
      end)

    schedule_follow()
    {:noreply, state}
  end

  # A preview node that stops on its own is forgotten.
  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(state.previews, fn {_branch, p} -> p.peer == pid end) do
      {branch, p} ->
        File.rm_rf(p.dir)
        :ets.delete(@table, branch)
        {:noreply, %{state | previews: Map.delete(state.previews, branch)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state),
    do: Enum.reduce(Map.keys(state.previews), state, &shut(&2, &1))

  defp start_preview(state, branch, opts) do
    running = state.previews[branch]
    keep? = opts[:keep] == true or Map.has_key?(state.kept, branch)

    cond do
      running != nil and running.versions == versions(branch) ->
        state = if keep?, do: keep(state, branch, running.port), else: state
        {{:ok, public(state.previews[branch])}, state}

      running != nil ->
        state = if keep?, do: keep(state, branch, running.port), else: state
        state = restart(state, branch, running)

        case state.previews[branch] do
          nil -> {{:error, :preview_failed}, state}
          p -> {{:ok, public(p)}, state}
        end

      not Branches.exists?(branch) ->
        {{:error, :no_such_branch}, state}

      Branches.closed?(branch) ->
        {{:error, "branch #{branch} is closed"}, state}

      true ->
        state = make_room(state)
        port = Keyword.get_lazy(opts, :port, &free_port/0)

        port =
          if opts[:any_port] == true and not free?(port), do: free_port(), else: port

        case boot(branch, port) do
          {:ok, preview} ->
            state = put_preview(state, branch, preview, keep?)
            state = if keep?, do: keep(state, branch, port), else: state
            Logger.info("preview of #{branch} at #{preview.url}")
            {{:ok, public(state.previews[branch])}, state}

          {:error, _} = error ->
            {error, state}
        end
    end
  end

  # At the cap, the preview used longest ago stops.
  defp make_room(state) do
    max = max(Keyword.get(Application.get_env(:theseus, :previews, []), :max, 4), 1)

    if map_size(state.previews) >= max do
      {branch, _} = Enum.min_by(state.previews, fn {_b, p} -> p.used end)
      Logger.info("stopping the preview of #{branch}, used longest ago, to start another")
      state |> shut(branch) |> unkeep(branch) |> make_room()
    else
      state
    end
  end

  defp restart(state, branch, p) do
    kept? = Map.has_key?(state.kept, branch)
    state = shut(state, branch)

    case boot(branch, p.port) do
      # A timed preview keeps its original end.
      {:ok, preview} ->
        put_preview(state, branch, preview, kept?, p.stops_at)

      {:error, reason} ->
        Logger.warning("preview of #{branch} did not start again: #{inspect(reason)}")
        state
    end
  end

  defp put_preview(state, branch, preview, kept?, stops_at \\ nil) do
    {timer, stops_at} =
      if kept? do
        {nil, nil}
      else
        stops_at =
          stops_at ||
            DateTime.add(
              DateTime.utc_now(),
              Application.get_env(:theseus, :preview_ms, 30 * 60_000),
              :millisecond
            )

        left = max(DateTime.diff(stops_at, DateTime.utc_now(), :millisecond), 0)
        {Process.send_after(self(), {:expire, branch}, left), stops_at}
      end

    preview =
      Map.merge(preview, %{
        timer: timer,
        stops_at: stops_at,
        versions: versions(branch),
        used: System.monotonic_time()
      })

    publish(%{state | previews: Map.put(state.previews, branch, preview)}, branch)
  end

  defp keep(state, branch, port) do
    state =
      case state.previews[branch] do
        %{timer: timer} = p when timer != nil ->
          Process.cancel_timer(timer)
          put_in(state.previews[branch], %{p | timer: nil, stops_at: nil})

        _ ->
          state
      end

    state =
      if state.kept[branch] == port do
        state
      else
        append(state, {:kept, branch, port})
        %{state | kept: Map.put(state.kept, branch, port)}
      end

    if state.previews[branch], do: publish(state, branch), else: state
  end

  defp unkeep(state, branch) do
    if Map.has_key?(state.kept, branch) do
      append(state, {:kept, branch, :deleted})
      %{state | kept: Map.delete(state.kept, branch)}
    else
      state
    end
  end

  defp publish(state, branch) do
    p = state.previews[branch]
    :ets.insert(@table, {branch, Map.put(public(p), :kept, Map.has_key?(state.kept, branch))})
    state
  end

  defp append(%{log: nil}, _record), do: :ok
  defp append(%{log: log}, record), do: Records.append(log, record)

  defp schedule_follow do
    ms = Keyword.get(Application.get_env(:theseus, :previews, []), :follow_ms, 3_000)
    Process.send_after(self(), :follow, ms)
  end

  defp versions(branch), do: Map.new(Branches.units(branch), &{&1.module, &1.current_version})

  defp public(p),
    do:
      p
      |> Map.take([:branch, :url, :local_url, :port, :started_at, :stops_at])
      |> Map.put(:data, data())

  defp shut(state, branch) do
    case Map.pop(state.previews, branch) do
      {nil, _} ->
        state

      {p, previews} ->
        if p.timer, do: Process.cancel_timer(p.timer)
        :peer.stop(p.peer)
        File.rm_rf(p.dir)
        :ets.delete(@table, branch)
        %{state | previews: previews}
    end
  end

  defp boot(branch, port) do
    dir = Path.join(System.tmp_dir!(), "theseus_preview_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    copy = Path.join(dir, "app.theseus")
    File.cp!(Ledger.path(), copy)

    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: Enum.flat_map(:code.get_path() -- [~c"."], &[~c"-pa", &1]) ++ [~c"-noinput"],
        wait_boot: 30_000
      })

    local = "http://127.0.0.1:#{port}"
    url = Theseus.PreviewProxy.address(branch) || local

    app =
      Application.get_env(:theseus, :app, [])
      |> Keyword.merge(
        server: true,
        port: port,
        ip: {127, 0, 0, 1},
        tick_seconds: 0,
        public_url: url
      )

    env =
      Application.get_all_env(:theseus)
      |> Enum.reject(fn {_k, v} -> is_function(v) or is_pid(v) end)
      |> Keyword.merge(
        ledger_path: copy,
        branch: branch,
        trace_file: false,
        state_file: false,
        connections_file: false,
        clients_file: false,
        team_file: false,
        previews_file: false,
        # A preview never sends messages.
        outbox_file: false,
        outbox: [adapter: :hold],
        store: store_env(),
        sign_in: Keyword.put(Application.get_env(:theseus, :sign_in, []), :dev, true),
        # A preview sends no requests to outside services.
        fetch: [enabled: false],
        crash_repair: [enabled: false],
        consolidate: [enabled: false],
        admin: [server: false, port: 0]
      )
      |> Keyword.put(:app, app)

    try do
      :ok = :peer.call(peer, :logger, :set_primary_config, [:level, :warning])
      :ok = :peer.call(peer, Application, :load, [:theseus])
      for {k, v} <- env, do: :ok = :peer.call(peer, Application, :put_env, [:theseus, k, v])
      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:theseus], 90_000)

      {:ok,
       %{
         branch: branch,
         peer: peer,
         port: port,
         dir: dir,
         url: url,
         local_url: local,
         started_at: DateTime.utc_now()
       }}
    catch
      kind, reason ->
        :peer.stop(peer)
        File.rm_rf(dir)
        {:error, {:preview_failed, Exception.format(kind, reason) |> String.slice(0, 500)}}
    end
  end

  @doc "Where previews get their data: `:made_up` or `:production`."
  @spec data() :: :made_up | :production
  def data do
    if Keyword.get(Application.get_env(:theseus, :previews, []), :data) == :production and
         Theseus.Store.DB.configured?(),
       do: :production,
       else: :made_up
  end

  # Made-up data never reaches the database: the preview has no url.
  defp store_env do
    case data() do
      :production -> Keyword.put(Application.get_env(:theseus, :store, []), :preview, true)
      :made_up -> [memory: true]
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp free?(port) do
    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end
end
