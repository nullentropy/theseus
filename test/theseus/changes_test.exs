defmodule Theseus.ChangesTest do
  @moduledoc "Phase 1 acceptance 3, 4, 5 and 7, driven directly (no MCP)."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Describe, Report}

  @basket %{"items" => [%{"sku" => "abc-1", "qty" => 3, "unit_cents" => 2000}]}

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)
    :ok
  end

  test "a unit and spec change is held, shows its evidence, and goes live on approval" do
    # Some real traffic for the behaviour comparison, and only this test's.
    Theseus.Traces.clear(Sample.Pricing)

    for qty <- [1, 3, 6] do
      post_price(%{"items" => [%{"sku" => "a", "qty" => qty, "unit_cents" => 1000}]})
    end

    {:ok, change, _report} =
      Changes.propose(
        proposal(
          intent: "make free shipping apply from 5000 cents instead of 10000",
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec(),
          rationale: "Lower the threshold and pin it with an example."
        )
      )

    assert change.status == :shadowing
    {change, report} = settle(change.id)
    assert change.status == :held
    assert report.passed, inspect(Report.failure(report))

    d = Describe.change(change, report)
    assert d.touches == ["unit", "spec"]

    # The traces whose shipping changes: 6000 and 5000 no longer pay shipping... 3000 still does.
    changed_calls = Enum.map(d.behaviour.changed, & &1.call)
    assert Enum.any?(changed_calls, &(&1 =~ "qty: 6"))
    refute Enum.any?(changed_calls, &(&1 =~ "qty: 1,"))

    assert [%{name: "free shipping from 5000"}] = d.spec_changes.examples_added
    assert "free shipping from 5000" in d.spec_changes.live_unit_misses
    assert d.spec_after.prose =~ "5000 or more"

    # Nothing is live yet.
    assert {200, %{"shipping_cents" => 599}} = post_price(@basket)

    {:ok, promoted} = Changes.approve(change.id, actor: :human)
    assert promoted.status == :promoted
    assert {200, %{"shipping_cents" => 0, "total_cents" => 6000}} = post_price(@basket)
    assert Theseus.Registry.spec(Sample.Pricing).prose =~ "5000 or more"

    history = Enum.map(Theseus.history(Sample.Pricing), & &1.event)
    assert Enum.any?(history, &(&1 =~ "#{change.id} proposed by test (test)"))
    assert Enum.any?(history, &(&1 =~ "#{change.id} approved (human)"))
    assert Enum.any?(history, &(&1 =~ "Sample.Pricing.Spec" and &1 =~ change.id))
  end

  test "a change that breaks a property is rejected at :properties and recorded" do
    broken =
      String.replace(
        cheaper_shipping_unit(),
        "total_cents: subtotal - discount + shipping",
        "total_cents: subtotal - discount + shipping + if(subtotal > 30_000, do: 1, else: 0)"
      )

    {:ok, change, report} = Changes.propose(proposal(intent: "break it", unit_source: broken))

    assert change.status == :rejected
    assert %{name: :properties} = Report.failure(report)
    assert {:ok, %{status: :rejected}, _} = Changes.get(change.id)

    d = Describe.change(change, report)
    lines = Enum.find(d.stages, &(&1.name == "properties")).lines

    assert Enum.any?(
             lines,
             &(&1 =~ "The total is the subtotal minus the discount plus shipping.")
           )
  end

  test "a change that shells out is rejected at :static before compiling" do
    evil =
      String.replace(
        fixture("pricing.ex"),
        "def total(items, rule) do",
        ~s|def total(items, rule) do\n    System.cmd("touch", ["/tmp/theseus_pwned"])|
      )

    {:ok, change, report} = Changes.propose(proposal(intent: "evil", unit_source: evil))

    assert change.status == :rejected
    assert %{name: :static, detail: %{violations: violations}} = Report.failure(report)
    assert violations[Sample.Pricing] |> Enum.any?(&(&1 =~ "System"))
    assert Enum.find(report.stages, &(&1.name == :compile)).result == :skip
  end

  test "a candidate that loops while compiling is stopped on the sandbox node, and the live app is unaffected" do
    Application.put_env(:theseus, :stage_timeout_ms, 1_000)
    on_exit(fn -> Application.put_env(:theseus, :stage_timeout_ms, 5_000) end)

    looping =
      String.replace(
        fixture("pricing.ex"),
        "@shipping_cents 599",
        "@shipping_cents 599\n  @spin Enum.reduce(1..100_000_000_000, 0, fn i, acc -> acc + i end)"
      )

    check = Task.async(fn -> Changes.check(proposal(intent: "loop", unit_source: looping)) end)

    # The loop runs on the sandbox node; the live app keeps answering.
    Process.sleep(300)
    {micros, {200, _}} = :timer.tc(fn -> post_price(@basket) end)
    assert micros < 100_000

    {:ok, _change, report} = Task.await(check, 30_000)
    assert %{name: :compile, detail: %{timeout_ms: 1_000}} = Report.failure(report)

    spinning =
      for pid <- Process.list(),
          {:current_function, {Enum, fun, _}} <- [Process.info(pid, :current_function)],
          fun in [:reduce_range, :reduce],
          do: pid

    assert spinning == []
  end

  test "a person can reject a held change" do
    {:ok, change, _} =
      Changes.propose(proposal(intent: "cheaper shipping", unit_source: cheaper_shipping_unit()))

    {:ok, rejected} = Changes.reject(change.id, "not now", actor: :human)
    assert rejected.status == :rejected
    assert {:error, {:not_held, :rejected}} = Changes.approve(change.id)
    assert {200, %{"shipping_cents" => 599}} = post_price(@basket)
  end

  test "code that compiles with warnings is refused at the compile stage" do
    warned =
      String.replace(
        fixture("pricing.ex"),
        "@free_shipping_from 10_000",
        "@free_shipping_from 10_000\n  def unused(x), do: :ok"
      )

    {:ok, _, report} = Changes.check(proposal(unit_source: warned, intent: "warn"))
    assert %{name: :compile, result: :fail, detail: %{errors: errors}} = Report.failure(report)

    assert errors[Sample.Pricing] ==
             {:warnings,
              [
                ~s|variable "x" is unused (if the variable is not meant to be used, prefix it with an underscore) (line 4)|
              ]}

    {:ok, change, _} = Changes.check(proposal(unit_source: warned, intent: "warn"))
    compile = Enum.find(Theseus.Describe.change(change, report).stages, &(&1.name == "compile"))
    assert hd(compile.lines) =~ "the compiler warns"
  end

  test "approving a change whose base moved on is refused as stale" do
    {:ok, first, _} = Changes.propose(proposal(intent: "a", unit_source: cheaper_shipping_unit()))
    settle(first.id)

    other =
      String.replace(
        fixture("pricing.ex"),
        "acc -> acc + qty * cents",
        "acc -> qty * cents + acc"
      )

    {:ok, second, _} = Changes.propose(proposal(intent: "b", unit_source: other))
    settle(second.id)

    {:ok, _} = Changes.approve(first.id)
    assert {:error, {:stale, _}} = Changes.approve(second.id)
    assert {:ok, %{status: :rejected}, _} = Changes.get(second.id)
  end

  test "a new unit with its spec is created on approval" do
    unit = """
    defmodule Sample.Greeting do
      def hello(name), do: "Hello, " <> name <> "!"
    end
    """

    spec = """
    defmodule Sample.Greeting.Spec do
      use Theseus.Spec

      spec Sample.Greeting do
        prose "Greets a person by name."
        example "greets Ada", hello: ["Ada"], expect: "Hello, Ada!"

        property "A greeting always ends with an exclamation mark.",
          hello: [string(:alphanumeric)],
          check: fn g -> String.ends_with?(g, "!") end
      end
    end
    """

    if match?({:ok, _}, Theseus.Registry.fetch(Sample.Greeting)) do
      assert Theseus.call(Sample.Greeting, :hello, ["Ada"]) == "Hello, Ada!"
    else
      assert {:error, msg} =
               Changes.propose(
                 proposal(unit: "Sample.Greeting", intent: "greet", unit_source: unit)
               )

      assert msg =~ "needs both"

      {:ok, change, report} =
        Changes.propose(
          proposal(
            unit: "Sample.Greeting",
            intent: "greet people",
            unit_source: unit,
            spec_source: spec
          )
        )

      assert report.passed, inspect(Report.failure(report))
      assert Describe.change(change, report).creates
      {:ok, _} = Changes.approve(change.id)
      assert Theseus.call(Sample.Greeting, :hello, ["Ada"]) == "Hello, Ada!"
      assert Theseus.Registry.spec(Sample.Greeting).prose == "Greets a person by name."
    end
  end

  test "Theseus modules and spec names cannot be proposed as units" do
    assert {:error, "Theseus modules can never be changed"} =
             Changes.propose(
               proposal(unit: "Theseus.Gate", unit_source: "defmodule Theseus.Gate do\nend")
             )

    assert {:error, msg} =
             Changes.propose(proposal(unit: "Sample.Pricing.Spec", spec_source: "x"))

    assert msg =~ "name the unit"
  end

  test "check_change validates without recording" do
    events = length(Theseus.Ledger.events())

    {:ok, change, report} =
      Changes.check(proposal(intent: "try", unit_source: cheaper_shipping_unit()))

    assert report.passed
    assert Changes.get(change.id) == :error
    assert length(Theseus.Ledger.events()) == events
  end

  test "an unchanged half of a proposal is dropped; an unchanged whole is refused" do
    {:ok, change, _report} =
      Changes.check(
        proposal(
          intent: "cheaper",
          unit_source: cheaper_shipping_unit(),
          spec_source: fixture("pricing_spec.ex")
        )
      )

    assert [%{unit: Sample.Pricing}] = change.candidates

    assert {:error, message} =
             Changes.check(
               proposal(
                 intent: "nothing",
                 unit_source: fixture("pricing.ex"),
                 spec_source: fixture("pricing_spec.ex")
               )
             )

    assert message =~ "no change from the current version"
  end

  test "a proposed spec is checked against the live unit on fresh server state" do
    # Live state differs from a fresh store: SAVE10 is switched off.
    :ok = Theseus.call(Sample.CouponStore, :deactivate, ["SAVE10"])
    on_exit(fn -> Theseus.call(Sample.CouponStore, :activate, ["SAVE10"]) end)

    spec =
      String.replace(
        fixture("routes_spec.ex"),
        ~s(    example "other requests are not found",),
        """
            example "other paths are not found either",
              handle: [%{method: "GET", path: ["price", "x"], query: %{}, body: %{}}],
              expect: {404, %{error: "not found"}}

            example "other requests are not found",
        """
        |> String.trim_trailing()
      )

    {:ok, change, report} = Changes.check(proposal(unit: "Sample.Routes", spec_source: spec))
    assert report.passed, inspect(Report.failure(report))

    d = Describe.change(change, report)
    assert [%{name: "other paths are not found either"}] = d.spec_changes.examples_added
    assert d.spec_changes.live_unit_misses == []
  end
end
