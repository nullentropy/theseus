defmodule Theseus.QueueTest do
  @moduledoc "Sandbox slots are shared in turn between the people proposing."

  use ExUnit.Case, async: false

  alias Theseus.Queue

  setup do
    before = Application.get_env(:theseus, :validation)
    Application.put_env(:theseus, :validation, slots: 1)

    on_exit(fn ->
      if before,
        do: Application.put_env(:theseus, :validation, before),
        else: Application.delete_env(:theseus, :validation)
    end)

    :ok
  end

  defp job(who, label) do
    test = self()

    spawn(fn ->
      Queue.run(who, fn ->
        send(test, {:started, label, self()})
        receive do: (:finish -> :ok)
      end)
    end)
  end

  defp started do
    receive do
      {:started, label, pid} -> {label, pid}
    after
      5_000 -> flunk("nothing started")
    end
  end

  defp waiting(n) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      total = Queue.status().waiting |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      if total == n, do: {:halt, :ok}, else: Process.sleep(10) && {:cont, nil}
    end)
  end

  test "a free slot goes to the next person in turn" do
    job(:ann, :a1)
    {:a1, a1} = started()
    job(:ann, :a2)
    job(:ann, :a3)
    :ok = waiting(2)
    job(:bob, :b1)
    :ok = waiting(3)
    assert %{running: [:ann], waiting: [ann: 2, bob: 1]} = Queue.status()

    order =
      for _ <- 1..3, reduce: {[], a1} do
        {seen, pid} ->
          send(pid, :finish)
          {label, next} = started()
          {seen ++ [label], next}
      end

    # Bob waits for one of Ann's, not all of them.
    assert {[:a2, :b1, :a3], last} = order
    send(last, :finish)
  end

  test "a process holding a slot runs again without waiting, and a dead caller frees its slot" do
    assert Queue.run(:ann, fn -> Queue.run(:ann, fn -> :inner end) end) == :inner
    assert %{waited: %{ahead: 0}} = %{waited: Queue.waited()}

    job(:ann, :a1)
    {:a1, a1} = started()
    Process.exit(a1, :kill)
    job(:bob, :b1)
    assert {:b1, b1} = started()
    send(b1, :finish)
  end
end
