defmodule Theseus.LedgerIndexTest do
  @moduledoc "Reads through the ledger's indexes and cache give what a full scan gives."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Branches, Changes, Event, Ledger, Version}

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)
    :ok
  end

  defp scanned_versions(module) do
    for(%Event{body: {:version_recorded, %Version{unit: ^module} = v}} <- Ledger.events(), do: v)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.hash)
    |> Enum.reverse()
  end

  defp agree! do
    events = Ledger.events()

    for unit <- Enum.uniq(for e <- events, e.unit != nil, do: e.unit) do
      scanned = Enum.filter(events, &(&1.unit == unit))
      assert Ledger.events_for(unit) == scanned
      assert Ledger.events_for(unit, limit: 2) == Enum.take(scanned, -2)
      assert Ledger.versions_for(unit) == scanned_versions(unit)
      assert Ledger.version_hashes(unit) == Enum.map(scanned_versions(unit), & &1.hash)
    end

    assert Ledger.recent(15) == Enum.take(events, -15)
    assert Ledger.recent(0) == []

    for %{name: branch} <- Branches.list() do
      assert Branches.units(branch) == Branches.units_in(events, branch)
    end
  end

  test "indexed reads match a scan of every event, also after a promotion" do
    agree!()
    approve_settled(unit_source: cheaper_shipping_unit(), intent: "cheaper shipping")
    agree!()
    assert Branches.current("main", Sample.Pricing) == current(Sample.Pricing)
  end

  test "a cached value is worked out again only after an event is appended" do
    key = {:test, System.unique_integer()}
    count = fn -> Process.put(:runs, Process.get(:runs, 0) + 1) end

    Ledger.memo(key, count)
    Ledger.memo(key, count)
    assert Process.get(:runs) == 1

    {:ok, _} = Ledger.append({:note, "cache test"}, actor: :system)
    Ledger.memo(key, count)
    assert Process.get(:runs) == 2
  end

  test "changes are filtered and ordered as before" do
    approve_settled(unit_source: cheaper_shipping_unit(), intent: "cheaper shipping")
    all = Changes.list(limit: :all)
    newest_first = Enum.sort_by(all, fn {c, _} -> c.at end, {:desc, DateTime})
    assert all == newest_first

    for opts <- [
          [status: :promoted],
          [unit: Sample.Pricing],
          [branch: "main"],
          [status: :held, unit: Sample.Pricing]
        ] do
      expected =
        Enum.filter(all, fn {c, _} ->
          Enum.all?(opts, fn {k, v} -> Map.get(c, k) == v end)
        end)

      assert Changes.list([limit: :all] ++ opts) == expected
      assert Changes.list([limit: 1] ++ opts) == Enum.take(expected, 1)
    end
  end
end
