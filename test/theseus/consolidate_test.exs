defmodule Theseus.ConsolidateTest do
  @moduledoc "Phase 4 acceptance: consolidation after many changes, and the dashboard."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Change, Changes, Consolidate, Report}
  alias Theseus.LLM.Stub

  @basket %{
    "items" => [%{"sku" => "c-1", "qty" => 3, "unit_cents" => 1995}],
    "coupon" => "SAVE10"
  }

  @clean """
  defmodule Sample.Pricing do
    @shipping_cents 599
    @free_shipping_from 10_000

    def total(items, rule) do
      subtotal = items |> Enum.map(&line_total/1) |> Enum.sum()
      discount = rule |> discount(subtotal) |> min(subtotal)
      shipping = shipping(rule, subtotal)

      %{
        subtotal_cents: subtotal,
        discount_cents: discount,
        shipping_cents: shipping,
        total_cents: subtotal - discount + shipping
      }
    end

    defp line_total(%{qty: qty, unit_cents: cents}), do: qty * cents

    defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)
    defp discount({:amount_off, cents}, _subtotal), do: cents
    defp discount(_rule, _subtotal), do: 0

    defp shipping(:free_shipping, _subtotal), do: 0
    defp shipping(_rule, subtotal) when subtotal >= @free_shipping_from, do: 0
    defp shipping(_rule, _subtotal), do: @shipping_cents
  end
  """

  setup do
    before = snapshot()
    config = Application.fetch_env!(:theseus, :consolidate)

    Application.put_env(
      :theseus,
      :consolidate,
      Keyword.merge(config, enabled: true, quiet_ms: 2_000)
    )

    # Changes other tests left waiting would hold the consolidation back.
    for {c, _} <- Changes.list(unit: Sample.Pricing, limit: :all),
        c.status in [:held, :shadowing],
        do: {:ok, _} = Changes.reject(c.id, "test cleanup")

    on_exit(fn ->
      Application.put_env(:theseus, :consolidate, config)
      Application.delete_env(:theseus, Stub)
      restore(before)
    end)

    :ok
  end

  # The same pricing, written differently each time: 599 + 0 * n is 599.
  defp variant(n),
    do:
      String.replace(
        fixture("pricing.ex"),
        "@shipping_cents 599",
        "@shipping_cents 599 + 0 * #{n}"
      )

  defp traffic, do: post_price(@basket)

  test "after 12 changes a consolidation runs, is promoted with no replay differences, and the dashboard shows the whole history" do
    Stub.reply(fn _system, _messages ->
      {:ok, "```elixir\n#{@clean}```\n```json\n{\"rationale\": \"Named the steps.\"}\n```"}
    end)

    since = DateTime.utc_now()
    {200, priced} = traffic()
    for _ <- 1..4, do: traffic()

    ids =
      for n <- 1..12 do
        {:ok, change, _} =
          Changes.propose(
            proposal(intent: "tidy step #{n}", unit_source: variant(n), behaviour_change: false)
          )

        {change, _} = settle(change.id, &traffic/0)
        assert change.status == :held
        {:ok, %{status: :promoted}} = Changes.approve(change.id)
        change.id
      end

    assert Consolidate.changes_since(Sample.Pricing) >= 12

    consolidation =
      wait_until(fn ->
        Enum.find_value(Changes.list(unit: Sample.Pricing), fn {c, _} ->
          if c.trigger.kind == :consolidate and DateTime.compare(c.at, since) == :gt, do: c
        end)
      end)

    {consolidation, report} = settle(consolidation.id, &traffic/0, 10_000)
    assert consolidation.status == :promoted
    assert consolidation.behaviour_change == false
    assert %{result: :pass, detail: %{compared: compared}} = Report.stage(report, :replay)
    assert compared > 0
    assert %{result: :pass, detail: %{differ: 0}} = Report.stage(report, :shadow)
    assert current(Sample.Pricing) == Change.unit_candidate(consolidation).hash
    assert Consolidate.changes_since(Sample.Pricing) == 0
    assert {200, ^priced} = post_price(@basket)

    history = whole_history("/history?unit=Sample.Pricing")
    for id <- ids, do: assert(history =~ id)
    assert history =~ consolidation.id
    assert history =~ "consolidating Sample.Pricing"
    assert history =~ "#{consolidation.id}</a> approved (auto)"

    dashboard = get("/")
    assert dashboard =~ "Changes since rewrite"
    assert dashboard =~ "Recent history"

    unit_page = get("/units/Sample.Pricing")
    assert unit_page =~ "Versions of the unit"
    assert unit_page =~ ~s(<a href="/changes/#{consolidation.id}">)
    refute unit_page =~ "defmodule"
  end

  defp get(path),
    do: Plug.Test.conn(:get, path) |> Theseus.Admin.Router.call([]) |> Map.fetch!(:resp_body)

  # Follows the "Older" links to the first event.
  defp whole_history(path) do
    html = get(path)

    case Regex.run(~r/<a href="(\/history\?[^"]+)">Older<\/a>/, html) do
      [_, older] -> html <> whole_history(String.replace(older, "&amp;", "&"))
      nil -> html
    end
  end

  defp wait_until(fun, timeout \\ 15_000),
    do: wait_until(fun, System.monotonic_time(:millisecond) + timeout, :loop)

  defp wait_until(fun, deadline, :loop) do
    cond do
      result = fun.() -> result
      System.monotonic_time(:millisecond) > deadline -> flunk("timed out")
      true -> Process.sleep(50) && wait_until(fun, deadline, :loop)
    end
  end
end
