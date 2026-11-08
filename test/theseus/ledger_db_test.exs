defmodule Theseus.LedgerDbTest do
  @moduledoc "The ledger in Postgres: one node writes it, another stands by and takes over."

  use ExUnit.Case, async: false

  alias Theseus.Version

  @moduletag :postgres

  @source "defmodule Demo.Kept do\n  def answer, do: 42\nend\n"

  setup do
    dir = Path.expand("../../tmp/ledger_db_#{System.unique_integer([:positive])}", __DIR__)
    File.mkdir_p!(dir)
    schema = "theseus_ledger_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf!(dir)

      Postgrex.query!(
        Theseus.Store.Pool,
        ~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE),
        []
      )
    end)

    %{path: Path.join(dir, "app.theseus"), schema: schema}
  end

  # A named peer runs Erlang distribution, so it follows a leader instead
  # of standing by.
  defp peer(path, schema, records, name \\ nil, extra \\ []) do
    dist = if name, do: %{name: name, args: [~c"-setcookie", ~c"theseus_ledger_test"]}, else: %{}
    paths = Enum.flat_map(:code.get_path() -- [~c"."], &[~c"-pa", &1])

    {:ok, peer, _node} =
      :peer.start_link(
        Map.merge(
          %{connection: :standard_io, args: paths ++ [~c"-noinput"], wait_boot: 30_000},
          dist,
          fn :args, a, b -> a ++ b end
        )
      )

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    store = Keyword.put(Application.get_env(:theseus, :store), :schema, schema)

    env =
      Application.get_all_env(:theseus)
      |> Enum.reject(fn {_k, v} -> is_function(v) or is_pid(v) end)
      |> Keyword.merge(
        ledger_path: path,
        store: store,
        records: records,
        ledger_standby_ms: 100,
        ledger_follow_ms: 100,
        branch: "main",
        trace_file: false,
        state_file: false,
        connections_file: false,
        outbox_file: false,
        outbox: [adapter: :hold],
        crash_repair: [enabled: false],
        consolidate: [enabled: false],
        app: [server: false],
        admin: [server: false, port: 0]
      )
      |> Keyword.merge(extra)

    :ok = :peer.call(peer, :logger, :set_primary_config, [:level, :error])
    :ok = :peer.call(peer, Application, :load, [:theseus])
    for {k, v} <- env, do: :ok = :peer.call(peer, Application, :put_env, [:theseus, k, v])
    peer
  end

  # The units are loaded again a moment after the ledger restarts.
  defp answers?(peer, n) do
    :peer.call(peer, Theseus, :call, [Demo.Kept, :answer, []]) == n
  catch
    _, _ -> false
  end

  defp start(peer), do: :peer.call(peer, Application, :ensure_all_started, [:theseus], 90_000)

  test "a file ledger moves in, and a standby takes over when the leader stops", %{
    path: path,
    schema: schema
  } do
    # A unit recorded in a ledger file, as an app has before the move.
    first = peer(path, schema, :files)
    {:ok, _} = start(first)
    {:ok, v} = Version.build(Demo.Kept, @source)
    {:ok, _} = :peer.call(first, Theseus.Loader, :register, [v, [kind: :pure, actor: :system]])
    :peer.stop(first)

    leader = peer(path, schema, :database)
    {:ok, _} = start(leader)
    assert File.exists?(path <> ".imported-to-database")
    assert 42 == :peer.call(leader, Theseus, :call, [Demo.Kept, :answer, []])

    {:ok, v2} = Version.build(Demo.Kept, String.replace(@source, "42", "43"), v.hash)
    {:ok, _} = :peer.call(leader, Theseus.Loader, :promote, [v2, [actor: :system]])

    # A second node waits for the lock and starts nothing.
    standby = peer(path, schema, :database)
    waiting = Task.async(fn -> start(standby) end)
    refute Task.yield(waiting, 1_500)
    refute :peer.call(standby, Process, :whereis, [Theseus.Registry])

    # It refuses to compact at once: it runs nothing.
    assert {:error, why} = :peer.call(standby, Theseus.Compact, :run, [path], 5_000)
    assert why =~ "this node is a standby"

    # The leader stops: the standby takes the lock, reads the ledger and runs.
    :peer.stop(leader)
    assert {:ok, _} = Task.await(waiting, 60_000)
    assert 43 == :peer.call(standby, Theseus, :call, [Demo.Kept, :answer, []])

    assert {:ok, %{dry_run: true}} =
             :peer.call(standby, Theseus.Compact, :run, [path, [dry_run: true]])

    # Losing the connection that holds the lock stops the ledger; it takes
    # the lock again, since no other node holds it, and the app goes on.
    before = :peer.call(standby, Process, :whereis, [Theseus.Ledger])
    web = :peer.call(standby, Process, :whereis, [Theseus.App])

    Postgrex.query!(
      Theseus.Store.Pool,
      "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid <> pg_backend_pid()",
      []
    )

    assert Enum.find_value(1..300, fn _ ->
             Process.sleep(50)
             now = :peer.call(standby, Process, :whereis, [Theseus.Ledger])

             now not in [nil, before] and answers?(standby, 43)
           end)

    # The app's HTTP server was stopped with the lock and runs again.
    assert Enum.find_value(1..100, fn _ ->
             Process.sleep(50)
             now = :peer.call(standby, Process, :whereis, [Theseus.App])
             now not in [nil, web]
           end)
  end

  test "the leader compacts the ledger in the database while it runs, and followers reload", %{
    path: path,
    schema: schema
  } do
    tag = System.unique_integer([:positive])
    leader = peer(path, schema, :database, :"theseus_cleader_#{tag}")
    {:ok, _} = start(leader)
    {:ok, v} = Version.build(Demo.Kept, @source)
    {:ok, _} = :peer.call(leader, Theseus.Loader, :register, [v, [kind: :pure, actor: :system]])

    last =
      Enum.reduce(1..4, v, fn n, parent ->
        {:ok, next} =
          Version.build(Demo.Kept, String.replace(@source, "42", "#{100 + n}"), parent.hash)

        {:ok, _} = :peer.call(leader, Theseus.Loader, :promote, [next, [actor: :system]])
        next
      end)

    follower = peer(path, schema, :database, :"theseus_cfollower_#{tag}")
    {:ok, _} = start(follower)

    assert {:ok, %{ast: ast}} =
             :peer.call(follower, Theseus.Ledger, :version, [Demo.Kept, v.hash])

    assert ast != nil

    # A node that does not run the app may not compact under the ones that do.
    other = peer(path, schema, :database)
    {:ok, _} = :peer.call(other, Application, :ensure_all_started, [:postgrex])
    assert {:error, why} = :peer.call(other, Theseus.Compact, :run, [path, [keep: 1, days: 0]])
    assert why =~ "a node is running this app's ledger"

    # Asked on the follower, the leader compacts.
    assert {:ok, stats} =
             :peer.call(follower, Theseus.Compact, :run, [path, [keep: 1, days: 0]], 60_000)

    assert stats.versions_compacted > 0
    assert stats.after_bytes < stats.before_bytes
    assert stats.archive == "_theseus_ledger_archive"

    %{rows: [[archived]]} =
      Postgrex.query!(
        Theseus.Store.Pool,
        "SELECT count(*)::int FROM \"#{schema}\"._theseus_ledger_archive",
        []
      )

    assert archived >= stats.records_changed

    # With archive_days set, a later run deletes what the archive got before.
    :ok = :peer.call(leader, Application, :put_env, [:theseus, :compaction, [archive_days: 0]])

    assert {:ok, %{records_changed: 0, archive_pruned: ^archived}} =
             :peer.call(follower, Theseus.Compact, :run, [path, [keep: 1, days: 0]], 60_000)

    :ok = :peer.call(leader, Application, :put_env, [:theseus, :compaction, []])

    # Both nodes now read the compacted ledger and carry on.
    for node <- [leader, follower] do
      assert eventually(fn ->
               {:ok, %{ast: nil}} =
                 :peer.call(node, Theseus.Ledger, :version, [Demo.Kept, v.hash])
             end)

      assert 104 == :peer.call(node, Theseus, :call, [Demo.Kept, :answer, []])
    end

    {:ok, v5} = Version.build(Demo.Kept, String.replace(@source, "42", "105"), last.hash)
    {:ok, _} = :peer.call(leader, Theseus.Loader, :promote, [v5, [actor: :system]])

    assert eventually(fn ->
             105 == :peer.call(follower, Theseus, :call, [Demo.Kept, :answer, []])
           end)

    # With no node running, a run compacts what 105 made old, and a node
    # boots on it.
    :peer.stop(follower)
    :peer.stop(leader)

    assert {:ok, %{versions_compacted: 1}} =
             :peer.call(other, Theseus.Compact, :run, [path, [keep: 1, days: 0]], 60_000)

    :peer.stop(other)
    again = peer(path, schema, :database)
    {:ok, _} = start(again)
    assert 105 == :peer.call(again, Theseus, :call, [Demo.Kept, :answer, []])
    assert :peer.call(again, Theseus.Ledger, :current, [Demo.Kept]) == v5.hash
  end

  @counter """
  defmodule Demo.Count do
    use GenServer
    def start_link(_opts \\\\ []), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
    def next, do: GenServer.call(__MODULE__, :next)
    @impl true
    def init(n), do: {:ok, n}
    @impl true
    def handle_call(:next, _from, n), do: {:reply, n + 1, n + 1}
    @impl true
    def code_change(_old, n, _extra), do: {:ok, n}
  end
  """

  defp eventually(fun) do
    Enum.find_value(1..200, fn _ ->
      Process.sleep(50)

      try do
        fun.()
      catch
        _, _ -> false
      end
    end)
  end

  test "a follower serves the units, calls server units on the leader and takes over", %{
    path: path,
    schema: schema
  } do
    tag = System.unique_integer([:positive])
    [leader_admin, follower_admin] = free_ports(2)

    # The calls a node recorded before it ran beside others stay with the
    # leader, in a file of its own.
    {file, []} = Theseus.TraceFile.open(path <> ".traces", Theseus.TraceFile.key())
    Theseus.TraceFile.close(file)

    leader =
      peer(path, schema, :database, :"theseus_leader_#{tag}",
        admin: [server: true, port: leader_admin],
        trace_file: true
      )

    {:ok, _} = start(leader)
    {:ok, v} = Version.build(Demo.Kept, @source)
    {:ok, _} = :peer.call(leader, Theseus.Loader, :register, [v, [kind: :pure, actor: :system]])
    refute File.exists?(path <> ".traces")
    assert [_] = Path.wildcard(path <> ".theseus_leader_#{tag}@*.traces")
    {:ok, c} = Version.build(Demo.Count, @counter)
    {:ok, _} = :peer.call(leader, Theseus.Loader, :register, [c, [kind: :server, actor: :system]])

    # A named second node does not wait for the lock: it starts and follows.
    # Rows reach a follower when the leader writes them; reading the table
    # every five seconds only backs that up.
    follower =
      peer(path, schema, :database, :"theseus_follower_#{tag}",
        admin: [server: true, port: follower_admin],
        ledger_follow_ms: 5_000
      )

    {:ok, _} = start(follower)
    assert :peer.call(follower, Theseus.Leader, :follower?, [])
    refute :peer.call(follower, Process, :whereis, [Theseus.Servers])
    assert 42 == :peer.call(follower, Theseus, :call, [Demo.Kept, :answer, []])

    # The server unit runs once, on the leader, whichever node is called.
    assert 1 == :peer.call(follower, Theseus, :call, [Demo.Count, :next, []])
    assert 2 == :peer.call(leader, Theseus, :call, [Demo.Count, :next, []])
    assert 3 == :peer.call(follower, Theseus, :call, [Demo.Count, :next, []])

    # The leader's replay set has the calls the follower recorded.
    assert [%{fun: :answer}] = :peer.call(leader, Theseus.Traces, :replay_set, [Demo.Kept])

    # A version promoted on the leader runs on the follower moments later.
    {:ok, v2} = Version.build(Demo.Kept, String.replace(@source, "42", "43"), v.hash)
    {:ok, _} = :peer.call(leader, Theseus.Loader, :promote, [v2, [actor: :system]])

    assert Enum.find_value(1..20, fn _ ->
             Process.sleep(50)
             43 == :peer.call(follower, Theseus, :call, [Demo.Kept, :answer, []])
           end)

    # The follower's admin port is the leader's: an MCP session opened
    # through one is known to the other.
    {200, headers, _} =
      mcp(follower_admin, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        }
      })

    session = :proplists.get_value(~c"mcp-session-id", headers)

    {200, _, body} =
      mcp(
        leader_admin,
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"},
        [{~c"mcp-session-id", session}, {~c"mcp-protocol-version", ~c"2025-11-25"}]
      )

    assert %{"result" => %{"tools" => [_ | _]}} = JSON.decode!(body)

    # A shadow on the leader compares the follower's live calls too.
    {:ok, cv} =
      Version.build(Demo.Shadowed, String.replace(@source, "Demo.Kept", "Demo.Shadowed"))

    {:ok, beam} = :peer.call(leader, Theseus.Loader, :compile, [cv])

    change = %Theseus.Change{
      id: "shadow-#{tag}",
      trigger: %{kind: :human},
      proposer: :test,
      intent: "test",
      unit: Demo.Kept,
      candidates: []
    }

    :ok =
      :peer.call(leader, Theseus.Shadow, :start, [
        change,
        %{calls: 100, ms: 60_000},
        {Demo.Shadowed, beam}
      ])

    assert eventually(fn ->
             :peer.call(follower, Theseus, :call, [Demo.Kept, :answer, []])
             %{compared: n} = :peer.call(leader, Theseus.Shadow, :progress, [change.id])
             n >= 3
           end)

    :ok = :peer.call(leader, Theseus.Shadow, :stop, [change.id])

    # A change made on the follower is made on the leader, and the follower
    # runs it when the call returns.
    {:ok, v3} = Version.build(Demo.Kept, String.replace(@source, "42", "44"), v2.hash)
    {:ok, _} = :peer.call(follower, Theseus.Loader, :promote, [v3, [actor: :system]])
    assert 44 == :peer.call(follower, Theseus, :call, [Demo.Kept, :answer, []])
    assert 44 == :peer.call(leader, Theseus, :call, [Demo.Kept, :answer, []])

    :peer.stop(leader)

    # The leader stops: the follower takes the lock and runs the server unit.
    assert eventually(fn -> :peer.call(follower, Theseus.Leader, :leader?, []) end)

    assert eventually(fn ->
             is_integer(:peer.call(follower, Theseus, :call, [Demo.Count, :next, []]))
           end)

    assert :peer.call(follower, Process, :whereis, [Theseus.Servers])
    assert 44 == :peer.call(follower, Theseus, :call, [Demo.Kept, :answer, []])
  end

  defp free_ports(n) do
    sockets = for _ <- 1..n, do: elem(:gen_tcp.listen(0, []), 1)
    ports = for s <- sockets, do: elem(:inet.port(s), 1)
    Enum.each(sockets, &:gen_tcp.close/1)
    ports
  end

  defp mcp(port, body, headers \\ []) do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{port}/mcp",
         [{~c"accept", ~c"application/json, text/event-stream"} | headers], ~c"application/json",
         JSON.encode!(body)},
        [timeout: 30_000],
        body_format: :binary
      )

    {status, headers, body}
  end
end
