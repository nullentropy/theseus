defmodule Theseus.TracesTest do
  use ExUnit.Case, async: false

  alias Theseus.{Trace, Traces}

  @unit Theseus.TracesTest.NotAUnit

  setup do
    Traces.clear(@unit)
    on_exit(fn -> Traces.clear(@unit) end)
  end

  defp record(args, result) do
    Traces.record(%Trace{
      id: System.unique_integer([:positive, :monotonic]),
      unit: @unit,
      fun: :f,
      args: args,
      result: result,
      at: DateTime.utc_now()
    })
  end

  defp fail(args), do: record(args, {:error, %RuntimeError{message: "boom"}, []})

  test "failing calls are kept once per distinct call, newest first, up to the cap" do
    for _ <- 1..3, do: fail([1])
    assert [%{args: [1], tags: [:failing]}] = Traces.failing(@unit)

    for i <- 2..250, do: fail([i])
    failing = Traces.failing(@unit)
    assert length(failing) == 200
    assert hd(failing).args == [250]
    refute Enum.any?(failing, &(&1.args == [1]))
  end

  test "the replay set is the ring buffer plus failing calls, once per call" do
    fail([:old])
    for i <- 1..520, do: record([rem(i, 7)], {:ok, i})

    refute Enum.any?(Traces.list(@unit), &(&1.args == [:old]))
    replay = Traces.replay_set(@unit)
    assert length(replay) == 8
    assert Enum.any?(replay, &(&1.args == [:old]))
    assert hd(replay).result == {:ok, 520}
  end

  test "a function called often does not push another function's calls out" do
    capacity = :persistent_term.get({Theseus.Traces, :capacity})

    trace = fn fun, i ->
      %Theseus.Trace{
        id: System.unique_integer([:positive, :monotonic]),
        unit: @unit,
        fun: fun,
        args: [i],
        result: {:ok, i},
        version: "v",
        at: DateTime.utc_now()
      }
    end

    Traces.record(trace.(:rare, 1))
    for i <- 1..(capacity + 10), do: Traces.record(trace.(:often, i))

    funs = Enum.map(Traces.list(@unit, limit: 10_000), & &1.fun)
    assert :rare in funs
    assert Enum.count(funs, &(&1 == :often)) == capacity
  end
end
