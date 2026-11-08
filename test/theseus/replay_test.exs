defmodule Theseus.ReplayTest do
  @moduledoc "Phase 2 acceptance: replay of recorded calls and shadow runs on live calls."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Change, Changes, Describe, Report, Shadow, Traces}

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)
    :ok
  end

  # The same pricing rules, written differently.
  @refactored """
  defmodule Sample.Pricing do
    @shipping_cents 599
    @free_shipping_from 10_000

    def total(items, rule) do
      subtotal = items |> Enum.map(fn %{qty: qty, unit_cents: cents} -> qty * cents end) |> Enum.sum()
      discount = rule |> discount(subtotal) |> min(subtotal)
      shipping = if free_shipping?(rule, subtotal), do: 0, else: @shipping_cents

      %{
        subtotal_cents: subtotal,
        discount_cents: discount,
        shipping_cents: shipping,
        total_cents: subtotal - discount + shipping
      }
    end

    defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)
    defp discount({:amount_off, cents}, _subtotal), do: cents
    defp discount(_rule, _subtotal), do: 0

    defp free_shipping?(:free_shipping, _subtotal), do: true
    defp free_shipping?(_rule, subtotal), do: subtotal >= @free_shipping_from
  end
  """

  # Rounds percent discounts instead of truncating them. Passes the spec,
  # but changes the result for some real baskets.
  defp rounding_refactor,
    do: replace!(@refactored, "div(subtotal * pct, 100)", "round(subtotal * pct / 100)")

  defp replace!(source, pattern, replacement) do
    assert source =~ pattern
    String.replace(source, pattern, replacement)
  end

  # 200 varied requests: several basket sizes, every coupon, no coupon.
  defp traffic(n \\ 200) do
    coupons = [nil, "SAVE10", "FIVEOFF", "SHIPFREE", "BOGUS"]

    for i <- 1..n do
      items =
        for j <- 0..rem(i, 3) do
          %{
            "sku" => "sku-#{j}",
            "qty" => rem(i * 7 + j, 5) + 1,
            "unit_cents" => rem(i * 1_337 + j * 101, 6_000) + 5
          }
        end

      body =
        case Enum.at(coupons, rem(i, 5)) do
          nil -> %{"items" => items}
          code -> %{"items" => items, "coupon" => code}
        end

      {200, _} = post_price(body)
    end

    :ok
  end

  defp one_call(qty \\ 3, unit_cents \\ 2_000, coupon \\ nil) do
    item = %{"sku" => "live", "qty" => qty, "unit_cents" => unit_cents}
    body = if coupon, do: %{"items" => [item], "coupon" => coupon}, else: %{"items" => [item]}
    post_price(body)
  end

  defp refactor(
         source,
         intent \\ "refactor for clarity, same behaviour",
         unit \\ "Sample.Pricing"
       ) do
    Changes.propose(
      proposal(unit: unit, intent: intent, unit_source: source, behaviour_change: false)
    )
  end

  test "a same-behaviour refactor passes replay and shadow with no differences and is promoted" do
    traffic()

    {:ok, change, report} = refactor(@refactored)
    assert change.status == :shadowing

    replay = Report.stage(report, :replay)
    assert replay.result == :pass
    assert replay.detail.compared >= 200
    assert Report.stage(report, :shadow).result == :running

    {change, report} = settle(change.id, fn -> one_call(Enum.random(1..9)) end)
    assert change.status == :held

    shadow = Report.stage(report, :shadow)
    assert shadow.result == :pass
    assert shadow.detail.compared > 0
    assert shadow.detail.differ == 0

    d = Describe.change(change, report)
    assert Enum.find(d.stages, &(&1.name == "shadow")).lines |> hd() =~ "gave the same result"

    {:ok, %{status: :promoted}} = Changes.approve(change.id)
    assert current(Sample.Pricing) == Change.unit_candidate(change).hash
    assert {200, %{"total_cents" => 6599}} = one_call()

    history = Enum.map(Theseus.history(Sample.Pricing), & &1.event)
    assert Enum.any?(history, &(&1 =~ "#{change.id} shadow run: all"))
  end

  test "a shadowed candidate's calls to other units are not recorded as live calls" do
    traffic(20)

    asks_coupons =
      replace!(
        @refactored,
        "def total(items, rule) do",
        "def total(items, rule) do\n    _ = Theseus.call(Sample.Coupons, :rule, [\"FROM-SHADOW\"])"
      )

    {:ok, change, _report} = refactor(asks_coupons)
    assert change.status == :shadowing
    {change, report} = settle(change.id, fn -> one_call(Enum.random(1..9)) end)
    assert change.status == :held
    assert Report.stage(report, :shadow).detail.compared > 0

    refute Enum.any?(Theseus.Traces.list(Sample.Coupons), &(&1.args == ["FROM-SHADOW"]))
  end

  test "a refactor that changes recorded results is rejected at :replay, with the calls shown" do
    traffic()

    {:ok, change, report} = refactor(rounding_refactor())
    assert change.status == :rejected
    assert %{name: :replay, detail: %{differ: differ}} = Report.failure(report)
    assert differ > 0
    assert Report.stage(report, :shadow).result == :skip

    d = Describe.change(change, report)
    assert d.failed_at == "replay"
    [line] = Enum.find(d.stages, &(&1.name == "replay")).lines
    assert line =~ "recorded calls behave differently, but the change says it keeps behaviour"

    assert d.behaviour.counts.changed == differ
    assert [row | _] = d.behaviour.changed
    assert row.call =~ ":percent, 10"
    assert row.before =~ "discount_cents"
    refute row.after =~ "Theseus.Candidate"
  end

  test "a refactor that differs only on live calls is rejected at :shadow" do
    # Recorded requests could show the difference through Sample.Routes,
    # which calls Sample.Pricing; this test is about live calls.
    Traces.clear(Sample.Pricing)
    Traces.clear(Sample.Routes)
    for qty <- 1..5, do: one_call(qty)

    {:ok, change, report} = refactor(rounding_refactor())
    assert Report.stage(report, :replay).result == :pass

    # 1995 cents with 10% off: 199 truncated, 200 rounded.
    {change, report} = settle(change.id, fn -> one_call(1, 1_995, "SAVE10") end)
    assert change.status == :rejected
    assert %{name: :shadow, detail: %{differ: differ}} = Report.failure(report)
    assert differ > 0

    d = Describe.change(change, report)
    assert [%{call: call} | _] = d.shadow.changed
    assert call =~ "unit_cents: 1995"
    assert {:error, {:not_held, :rejected}} = Changes.approve(change.id)
  end

  test "a behaviour change reports differences instead of failing, and the review page lists them" do
    traffic()

    {:ok, change, report} =
      Changes.propose(
        proposal(
          intent: "make free shipping apply from 5000 cents instead of 10000",
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec()
        )
      )

    assert %{result: :info, detail: %{differ: recorded}} = Report.stage(report, :replay)
    assert recorded > 0

    {change, report} = settle(change.id, fn -> one_call() end)
    assert change.status == :held
    assert %{result: :info, detail: %{differ: live}} = Report.stage(report, :shadow)
    assert live > 0

    html =
      Plug.Test.conn(:get, "/changes/#{change.id}")
      |> Theseus.Admin.Router.call([])
      |> Map.fetch!(:resp_body)

    assert html =~ "Effect on recorded calls"
    assert html =~ "Effect on live calls"
    assert html =~ "is meant to change behaviour"
    assert html =~ "unit_cents: 2000"
    assert html =~ "shipping_cents: 599"
    assert html =~ "shipping_cents: 0"
    refute html =~ "defmodule"
  end

  test "failing calls stay in the replay set after the ring buffer moves on" do
    crash = %{"items" => [%{"sku" => "naïve", "qty" => 1, "unit_cents" => 100}]}
    assert {500, _} = post_price(crash)

    for i <- 1..510 do
      {:ok, _} = Theseus.call(Sample.Input, :parse, [%{"items" => [], "coupon" => "c#{i}"}])
    end

    refute Enum.any?(Traces.list(Sample.Input), &match?({:error, _, _}, &1.result))
    assert [%{tags: [:failing]} | _] = Traces.failing(Sample.Input)

    # Dropping characters it used to crash on is a behaviour change.
    keep =
      "  defp sku_char(char) when char in ?A..?Z or char in ?0..?9 or char == ?-, do: <<char>>"

    safe = replace!(fixture("input.ex"), keep, keep <> "\n  defp sku_char(_char), do: \"\"")

    {:ok, change, report} = refactor(safe, "tidy the sku parser, same behaviour", "Sample.Input")
    assert change.status == :rejected
    assert %{name: :replay} = Report.failure(report)
    assert [%{call: call} | _] = Describe.change(change, report).behaviour.now_succeed
    assert call =~ "naïve"
  end

  test "rejecting a change while it is shadowing stops its shadow run" do
    {:ok, change, _} = refactor(@refactored)
    assert Shadow.running?(change.id)

    {:ok, %{status: :rejected}} = Changes.reject(change.id, "changed my mind")
    refute Shadow.running?(change.id)
    assert {:error, {:not_held, :rejected}} = Changes.approve(change.id)
  end

  test "a change cannot be approved while it is shadowing" do
    {:ok, change, _} = refactor(@refactored)
    assert {:error, {:not_held, :shadowing}} = Changes.approve(change.id)
    {change, _} = settle(change.id)
    assert change.status == :held
  end

  test "a candidate that hangs on a live call never slows the live call, and is killed" do
    hangs =
      @refactored
      |> replace!(
        "  def total(items, rule) do\n",
        "  def total(items, rule) do\n    if Enum.any?(items, &(&1.unit_cents == 77_777)), do: spin(0)\n"
      )
      |> replace!(
        "  defp discount({:percent",
        "  defp spin(n), do: spin(n + 1)\n  defp discount({:percent"
      )

    {:ok, change, report} = refactor(hangs)
    assert report.passed, inspect(Report.failure(report))
    assert change.status == :shadowing

    {micros, {200, _}} = :timer.tc(fn -> one_call(1, 77_777) end)
    assert micros < 200_000

    {_change, _report} = settle(change.id)

    stuck =
      for pid <- Process.list(),
          {:current_function, {module, _, _}} <- [Process.info(pid, :current_function)],
          String.starts_with?(inspect(module), "Theseus.Candidate"),
          do: pid

    assert stuck == []
  end

  test "a shadow run cut short by a restart is recorded, and the change is held" do
    {:ok, change, _} = refactor(@refactored)
    :ok = Shadow.stop(change.id)

    ref = Process.monitor(Process.whereis(Changes))
    Process.exit(Process.whereis(Changes), :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    wait_for(fn -> Process.whereis(Changes) != nil end)
    # The name is registered before init has replayed the ledger.
    :sys.get_state(Changes)

    {:ok, change, report} = Changes.get(change.id)
    assert change.status == :held
    assert %{result: :skip, detail: %{reason: reason}} = Report.stage(report, :shadow)
    assert reason =~ "restarted"
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait_for(fun, tries - 1)
    end
  end

  test "recorded calls to a function the live unit does not have are left out" do
    Traces.clear(Sample.Pricing)
    for qty <- 1..3, do: one_call(qty)

    Traces.record(%Theseus.Trace{
      id: System.unique_integer([:positive, :monotonic]),
      unit: Sample.Pricing,
      fun: :price,
      args: [[%{qty: 1, unit_cents: 100}], nil],
      result: {:ok, %{}},
      version: "an-older-version",
      at: DateTime.utc_now()
    })

    {:ok, _change, report} =
      refactor(
        String.replace(fixture("pricing.ex"), "@shipping_cents 599", "@shipping_cents 600 - 1")
      )

    assert %{result: :pass, detail: %{compared: n}} = Report.stage(report, :replay)
    assert n == 3
  end
end
