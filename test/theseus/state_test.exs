defmodule Theseus.StateTest do
  @moduledoc "Server units' state survives crashes and restarts."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Servers, State}

  @store Sample.CouponStore

  setup do
    before = snapshot()
    dir = Path.expand("../../tmp/test_state_#{System.unique_integer([:positive])}", __DIR__)
    env = Application.get_all_env(:theseus) |> Keyword.take([:state_file, :state_path])

    Application.put_env(:theseus, :state_file, true)
    Application.put_env(:theseus, :state_path, Path.join(dir, "app.theseus.state"))
    restart_state()

    on_exit(fn ->
      Application.put_env(:theseus, :state_file, Keyword.get(env, :state_file, false))
      Application.delete_env(:theseus, :state_path)
      restart_state()
      restore(before)
      # The coupon store goes back to its defaults for other tests.
      :ok = Servers.stop(@store)
      :ok = Servers.start(@store)
    end)

    %{path: Path.join(dir, "app.theseus.state")}
  end

  defp restart_state do
    :ok = Supervisor.terminate_child(Theseus.Supervisor, State)
    {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, State)
  end

  # Stops Theseus.State (which saves), restarts the server unit with fresh
  # state, then starts Theseus.State again, as a reboot does.
  defp reboot do
    :ok = Supervisor.terminate_child(Theseus.Supervisor, State)
    :ok = Servers.stop(@store)
    :ok = Servers.start(@store)
    {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, State)
  end

  defp saved_soon(module) do
    Enum.find_value(1..100, fn _ ->
      Process.sleep(10)
      State.saved()[module]
    end)
  end

  test "state is saved after a call and comes back after a crash" do
    :ok = Theseus.call(@store, :activate, ["KEEPME"])
    assert %{bytes: bytes, version: version} = saved_soon(@store)
    assert bytes > 0
    assert version == current(@store)

    {:ok, pid} = Servers.pid(@store)
    Process.exit(pid, :kill)

    Enum.find_value(1..100, fn _ ->
      Process.sleep(10)
      match?({:ok, new} when new != pid, Servers.pid(@store))
    end)

    assert Theseus.call(@store, :active?, ["KEEPME"])
  end

  test "state comes back after a restart, and the file holds no readable text", %{path: path} do
    :ok = Theseus.call(@store, :activate, ["REBOOTED"])
    assert saved_soon(@store)
    reboot()
    assert Theseus.call(@store, :active?, ["REBOOTED"])
    assert Theseus.call(@store, :active?, ["SAVE10"])
    refute File.read!(path) =~ "REBOOTED"
  end

  test "state saved by an older version is migrated with code_change/3 on restart" do
    :ok = Theseus.call(@store, :activate, ["OLDER"])
    assert %{version: old} = saved_soon(@store)

    # Stop saving, then upgrade: the file still holds the old version's state.
    :ok = Supervisor.terminate_child(Theseus.Supervisor, State)

    approve_settled(
      unit: "Sample.CouponStore",
      intent: "count uses",
      unit_source: counting_coupon_store()
    )

    refute current(@store) == old

    :ok = Servers.stop(@store)
    :ok = Servers.start(@store)
    {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, State)

    assert Theseus.call(@store, :active?, ["OLDER"])
    assert Theseus.call(@store, :uses, ["OLDER"]) == 0
    current = current(@store)

    assert Enum.find_value(1..100, fn _ ->
             Process.sleep(10)
             match?(%{version: ^current}, State.saved()[@store])
           end)
  end

  test "state that cannot be migrated is set aside and the unit starts fresh", %{path: path} do
    :ok = Theseus.call(@store, :activate, ["STRANDED"])
    assert saved_soon(@store)
    :ok = Supervisor.terminate_child(Theseus.Supervisor, State)

    strict =
      String.replace(
        counting_coupon_store(),
        "  def code_change(_old_vsn, %MapSet{} = codes, _extra), do: {:ok, %{codes: codes, uses: %{}}}",
        """
          def code_change(_old_vsn, %MapSet{} = codes, _extra) do
            if MapSet.member?(codes, "STRANDED"),
              do: {:error, :cannot_migrate},
              else: {:ok, %{codes: codes, uses: %{}}}
          end
        """
      )

    # The running store can migrate; the saved one cannot.
    :ok = Theseus.call(@store, :deactivate, ["STRANDED"])

    approve_settled(unit: "Sample.CouponStore", intent: "strict", unit_source: strict)
    :ok = Servers.stop(@store)
    :ok = Servers.start(@store)

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, State)
    end)

    refute Theseus.call(@store, :active?, ["STRANDED"])
    assert File.exists?(path <> ".unrestored")
  end

  test "a state holding a pid is not saved, and says why" do
    n = System.unique_integer([:positive])
    unit = "Toy.Holder#{n}"

    approve_settled(
      unit: unit,
      intent: "hold a pid",
      unit_source: """
      defmodule #{unit} do
        use GenServer
        def start_link(opts \\\\ []), do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
        def ping(server \\\\ __MODULE__), do: GenServer.call(server, :ping)
        @impl true
        def init(:ok), do: {:ok, %{me: self()}}
        @impl true
        def handle_call(:ping, _from, s), do: {:reply, :pong, s}
        @impl true
        def code_change(_old, s, _extra), do: {:ok, s}
      end
      """,
      spec_source: """
      defmodule #{unit}.Spec do
        use Theseus.Spec

        spec #{unit} do
          prose "Answers pings."

          invariant "A ping gets a pong.",
            check: fn call ->
              {:ok, s} = call.(:start_link, [[name: nil]])
              call.(:ping, [s]) == :pong
            end
        end
      end
      """
    )

    module = Module.concat([unit])

    ExUnit.CaptureLog.capture_log(fn ->
      assert Theseus.call(module, :ping, []) == :pong
      assert %{error: reason} = saved_soon(module)
      assert reason =~ "pid"
    end)
  end

  test "a server unit's recorded calls replay in order, from a copy of the live state" do
    Theseus.Traces.clear(@store)
    :ok = Theseus.call(@store, :activate, ["LATE"])
    true = Theseus.call(@store, :active?, ["LATE"])
    :ok = Theseus.call(@store, :deactivate, ["SAVE10"])
    false = Theseus.call(@store, :active?, ["SAVE10"])
    on_exit(fn -> Theseus.call(@store, :activate, ["SAVE10"]) end)

    # Same behaviour, written differently.
    tidy =
      String.replace(
        fixture("coupon_store.ex"),
        "def handle_call({:activate, code}, _from, codes), do: {:reply, :ok, MapSet.put(codes, code)}",
        "def handle_call({:activate, code}, _from, codes), do: {:reply, :ok, MapSet.union(codes, MapSet.new([code]))}"
      )

    {:ok, _change, report} =
      Theseus.Changes.check(
        proposal(
          unit: "Sample.CouponStore",
          intent: "tidy",
          unit_source: tidy,
          behaviour_change: false
        )
      )

    assert %{result: :pass, detail: %{compared: 4}} = Theseus.Report.stage(report, :replay)

    # Codes stop counting once used up: active? now answers differently.
    stricter =
      String.replace(
        fixture("coupon_store.ex"),
        "do: {:reply, MapSet.member?(codes, code), codes}",
        "do: {:reply, MapSet.member?(codes, code) and code != \"LATE\", codes}"
      )

    {:ok, _change, report} =
      Theseus.Changes.check(
        proposal(unit: "Sample.CouponStore", intent: "no LATE", unit_source: stricter)
      )

    assert %{result: :info, detail: %{compared: 4, differ: 1}} =
             Theseus.Report.stage(report, :replay)
  end

  test "a server unit change runs beside the live process on live calls" do
    tidy =
      String.replace(
        fixture("coupon_store.ex"),
        "def handle_call({:activate, code}, _from, codes), do: {:reply, :ok, MapSet.put(codes, code)}",
        "def handle_call({:activate, code}, _from, codes), do: {:reply, :ok, MapSet.union(codes, MapSet.new([code]))}"
      )

    {:ok, change, report} =
      Theseus.Changes.propose(
        proposal(
          unit: "Sample.CouponStore",
          intent: "tidy",
          unit_source: tidy,
          behaviour_change: false
        )
      )

    assert %{result: :running} = Theseus.Report.stage(report, :shadow)

    # Activations reach both processes in order, so the candidate's answers
    # follow the live ones.
    {change, report} =
      settle(change.id, fn ->
        code = "C#{System.unique_integer([:positive])}"
        :ok = Theseus.call(@store, :activate, [code])
        true = Theseus.call(@store, :active?, [code])
      end)

    assert change.status == :held
    assert %{result: :pass, detail: %{compared: n}} = Theseus.Report.stage(report, :shadow)
    assert n >= 10
    {:ok, _} = Theseus.Changes.reject(change.id, "test")
  end
end

defmodule Theseus.StateDeltaTest do
  @moduledoc "Saves write only what changed, and what they write rebuilds the state."

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Theseus.TestHelpers

  alias Theseus.{Keys, SealedLog, Servers, State}

  @store Sample.CouponStore

  property "the changes applied to the saved state give the current one" do
    leaf = one_of([integer(), string(:alphanumeric), boolean(), constant(nil)])
    key = one_of([atom(:alphanumeric), string(:alphanumeric, max_length: 3), integer(0..5)])

    tree =
      tree(leaf, fn inner ->
        one_of([
          map_of(key, inner, max_length: 4),
          list_of(inner, max_length: 4),
          tuple({inner, inner})
        ])
      end)

    check all(
            old <- tree,
            new <- tree,
            front <- list_of(leaf, max_length: 3),
            current <- member_of([new, grow(old, new), front ++ List.wrap(old), {old, new}])
          ) do
      case State.compare({"v", old}, "v", current) do
        :same -> assert current == old
        {:delta, ops} -> assert State.apply_ops(old, ops) == current
        {:full, ^current} -> :ok
      end
    end
  end

  # `old` with one part changed, as a running unit changes its state.
  defp grow(old, new) when is_map(old) and map_size(old) > 0,
    do: Map.put(old, hd(Map.keys(old)), new)

  defp grow({a, _b}, new), do: {a, new}
  defp grow(old, new) when is_list(old), do: [new | old]
  defp grow(_old, new), do: new

  test "only what changed is written: keys, tuple elements, and what a list gained in front" do
    state = %{big: Map.new(1..1_000, &{&1, &1}), log: Enum.to_list(1..500), pair: {1, %{a: 1}}}
    saved = {"v", state}
    assert State.compare(saved, "v", state) == :same

    assert {:delta, [{:put, [{:k, :big}, {:k, 7}], 8}]} =
             State.compare(saved, "v", put_in(state, [:big, 7], 8))

    assert {:delta, [{:prepend, [{:k, :log}], [0]}]} =
             State.compare(saved, "v", Map.update!(state, :log, &[0 | &1]))

    assert {:delta, [{:put, [{:k, :pair}, {:e, 1}, {:k, :a}], 2}]} =
             State.compare(saved, "v", %{state | pair: {1, %{a: 2}}})

    # A list that lost items is written whole, at its place.
    assert {:delta, [{:put, [{:k, :log}], [1]}]} = State.compare(saved, "v", %{state | log: [1]})

    # A top-level list that grew, and a tuple state.
    assert {:delta, [{:prepend, [], [:new]}]} =
             State.compare({"v", [:a, :b]}, "v", [:new, :a, :b])

    assert {:delta, [{:put, [{:e, 0}], 2}]} = State.compare({"v", {1, :x}}, "v", {2, :x})
    assert {:full, ^state} = State.compare(saved, "w", state)
    assert {:full, 5} = State.compare({"v", 4}, "v", 5)
    assert {:error, _} = State.compare(saved, "v", Map.put(state, :pid, self()))
  end

  setup do
    before = snapshot()
    dir = Path.expand("../../tmp/test_state_#{System.unique_integer([:positive])}", __DIR__)
    env = Application.get_all_env(:theseus) |> Keyword.take([:state_file, :state_path])
    path = Path.join(dir, "app.theseus.state")
    Application.put_env(:theseus, :state_file, true)
    Application.put_env(:theseus, :state_path, path)
    restart_state()

    on_exit(fn ->
      Application.put_env(:theseus, :state_file, Keyword.get(env, :state_file, false))
      Application.delete_env(:theseus, :state_path)
      restart_state()
      restore(before)
      :ok = Servers.stop(@store)
      :ok = Servers.start(@store)
    end)

    %{path: path}
  end

  defp restart_state do
    :ok = Supervisor.terminate_child(Theseus.Supervisor, State)
    {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, State)
  end

  defp records(path) do
    {file, records} = SealedLog.open(path, Keys.state(), "THESEUSS")
    SealedLog.close(file)
    for r <- records, elem(r, 1) == @store, do: r
  end

  test "each save after the first writes only the codes that changed, and a reboot rebuilds the state",
       %{path: path} do
    for i <- 1..200, do: :ok = Theseus.call(@store, :activate, ["BULK#{i}"])
    :ok = State.flush()
    :ok = Theseus.call(@store, :activate, ["ONE-MORE"])
    :ok = State.flush()
    :ok = Theseus.call(@store, :deactivate, ["BULK7"])
    :ok = State.flush()

    written = records(path)

    assert [
             {:state_ops, @store, _, [{:put, [{:k, :map}, {:k, "ONE-MORE"}], []}], _},
             {:state_ops, @store, _, [{:drop, [{:k, :map}, {:k, "BULK7"}]}], _}
           ] = Enum.take(written, -2)

    # Nothing changed: nothing is written.
    :ok = State.flush()
    assert length(records(path)) == length(written)

    # As a reboot does: the deltas are folded into one snapshot.
    :ok = Supervisor.terminate_child(Theseus.Supervisor, State)
    :ok = Servers.stop(@store)
    :ok = Servers.start(@store)
    {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, State)

    assert Theseus.call(@store, :active?, ["ONE-MORE"])
    assert Theseus.call(@store, :active?, ["BULK200"])
    refute Theseus.call(@store, :active?, ["BULK7"])
    assert [{:state, @store, _, %MapSet{}, _}] = records(path)

    # After a restore the process holds what is saved: the next save is a delta.
    :ok = Theseus.call(@store, :activate, ["AFTER"])
    :ok = State.flush()

    assert {:state_ops, @store, _, [{:put, [{:k, :map}, {:k, "AFTER"}], []}], _} =
             List.last(records(path))
  end

  test "once a unit's deltas outgrow its snapshot, a whole snapshot replaces them", %{path: path} do
    for i <- 1..40 do
      :ok = Theseus.call(@store, :activate, ["ONE#{i}"])
      :ok = State.flush()
    end

    kinds = path |> records() |> Enum.map(&elem(&1, 0))
    wholes = Enum.count(kinds, &(&1 == :state))
    assert wholes >= 2 and wholes < 20
    # Each fold keeps the deltas since the last snapshot smaller than it.
    assert %{bytes: bytes} = State.saved()[@store]
    {_, %MapSet{} = state} = List.last(for {:state, _, v, s, _} <- records(path), do: {v, s})
    assert bytes < 3 * byte_size(:erlang.term_to_binary(state)) + 200
  end
end
