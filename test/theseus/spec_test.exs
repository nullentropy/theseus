defmodule Theseus.SpecTest do
  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.Spec

  test "every sample spec passes against the loaded unit" do
    for unit <- [Sample.Input, Sample.Coupons, Sample.Pricing, Sample.CouponStore] do
      report = Spec.run(unit, nil, runs: 50)

      assert report.passed,
             "#{inspect(unit)}: #{inspect(Enum.reject(report.results, &(&1.result == :pass)))}"
    end
  end

  test "before_each runs before every example, property and invariant" do
    spec = Sample.Pricing.Spec.__spec__()
    rules = length(spec.examples) + length(spec.properties) + length(spec.invariants)
    counter = :counters.new(1, [])

    report = Spec.run(spec, nil, runs: 5, before_each: fn -> :counters.add(counter, 1, 1) end)
    assert report.passed
    assert :counters.get(counter, 1) == rules
  end

  test "an invariant can call the app, and a failing one says what it raised" do
    spec = %Spec{
      unit: Sample.Pricing,
      invariants: [
        %{name: "uses the app", check: fn _call, app -> app.(:handle, [:ping]) == :pong end},
        %{name: "raises", check: fn call -> {:ok, _} = call.(:total, [[], nil]) end},
        %{name: "no app", check: fn _call, app -> app.(:handle, [:ping]) == :pong end}
      ]
    }

    app = fn :handle, [:ping] -> :pong end
    with_app = Spec.run(spec, nil, app: app)
    without = Spec.run(spec, nil)

    assert [%{result: :pass}, %{result: {:fail, %{raised: raised}}}, %{result: :pass} | _] =
             with_app.results

    assert raised =~ "no match of right hand side value"
    assert [_, _, %{result: {:fail, %{raised: no_app}}}] = without.results
    assert no_app =~ "app is only available when validation runs the spec"
  end

  test "a broken module fails with a failed example and a counterexample" do
    Code.compile_string("""
    defmodule BrokenPricing do
      def total(items, _rule) do
        subtotal = Enum.reduce(items, 0, fn i, acc -> acc + i.qty * i.unit_cents end)
        %{subtotal_cents: subtotal, discount_cents: 0, shipping_cents: 0, total_cents: -1}
      end
    end
    """)

    report = Spec.run(Sample.Pricing, BrokenPricing, runs: 50)
    refute report.passed

    failed = for %{result: {:fail, _}} = r <- report.results, into: %{}, do: {r.name, r.result}
    assert {:fail, %{got: %{total_cents: -1}}} = failed["no coupon, under free shipping"]
    assert {:fail, %{counterexample: %{args: [_, _]}}} = failed["The total is never negative."]
    assert {:fail, %{}} = failed["An empty basket costs only shipping."]
  end

  test "the readable form has prose, examples and rules, and no code" do
    d = Spec.describe(Theseus.Registry.spec(Sample.Pricing))
    assert d.prose =~ "Shipping is 599 cents"

    assert %{name: "percent coupon", call: "total([%{qty: 4, unit_cents: 2500}], {:percent, 10})"} =
             Enum.at(d.examples, 2)

    assert "The total is never negative." in d.rules
    assert "An empty basket costs only shipping." in d.invariants
  end

  describe "rules kept under the same sentence" do
    defp spec_ast(body) do
      {:ok, v} =
        Theseus.Version.build(Demo.Thing.Spec, """
        defmodule Demo.Thing.Spec do
          use Theseus.Spec

          spec Demo.Thing, deterministic: true do
            prose "A thing."
        #{body}
          end

          defp small, do: integer(0..10)
          defp big, do: integer(0..1000)
          defp wrapped, do: list_of(small())
        end
        """)

      v.ast
    end

    test "a rule whose check or generator changes is listed; others are not" do
      before =
        spec_ast("""
            property "It is never negative.", f: [small()], check: fn x -> x >= 0 end
            property "It is small.", f: [wrapped()], check: fn x -> x < 100 end
            invariant "It starts at zero.", check: fn call -> call.(:f, [0]) == 0 end
        """)

      after_ =
        spec_ast("""
            property "It is never negative.", f: [big()], check: fn x -> x >= 0 end
            property "It is small.", f: [wrapped()], check: fn x -> x < 100 end
            invariant "It starts at zero.", check: fn call -> call.(:f, [0]) == 1 end
        """)

      assert Enum.sort(Theseus.Spec.changed_rules(before, after_)) ==
               ["It is never negative.", "It starts at zero."]

      assert Theseus.Spec.changed_rules(before, before) == []
    end

    test "a change to a helper a rule reaches through another helper counts" do
      base = """
          property "It is small.", f: [wrapped()], check: fn x -> x < 100 end
      """

      before = spec_ast(base)

      after_ =
        Theseus.Unit.rename_references(spec_ast(base), %{})
        |> Macro.prewalk(fn
          {:defp, m, [{:small, m2, c}, [do: _]]} ->
            {:defp, m, [{:small, m2, c}, [do: quote(do: integer(0..50))]]}

          node ->
            node
        end)

      assert Theseus.Spec.changed_rules(before, after_) == ["It is small."]
    end
  end

  test "a proposal that changes a rule's check under the same sentence says so" do
    spec =
      String.replace(
        fixture("pricing_spec.ex"),
        "check: fn %{total_cents: t} -> t >= 0 end",
        "check: fn %{total_cents: t} -> t >= -1 end"
      )

    {:ok, change, report} =
      Theseus.Changes.check(proposal(intent: "loosen a rule", spec_source: spec))

    d = Theseus.Describe.change(change, report)
    assert d.spec_changes.rules_changed == ["The total is never negative."]
    assert d.spec_changes.rules_added == [] and d.spec_changes.rules_removed == []
  end

  describe "the model reads new and changed rules" do
    setup do
      llm = Application.get_env(:theseus, :llm)
      Application.put_env(:theseus, :llm, Keyword.put(llm, :rule_check, true))

      on_exit(fn ->
        Application.put_env(:theseus, :llm, llm)
        Application.delete_env(:theseus, Theseus.LLM.Stub)
      end)
    end

    defp spec_with_loose_rule do
      fixture("pricing_spec.ex")
      |> String.replace(
        "check: fn %{total_cents: t} -> t >= 0 end",
        "check: fn %{total_cents: t} -> t >= -1 end"
      )
    end

    defp wait_for_rules(id) do
      Enum.find_value(1..200, fn _ ->
        Process.sleep(10)
        {:ok, _change, report} = Theseus.Changes.get(id)
        Theseus.Report.stage(report, :rules)
      end)
    end

    test "its verdict on each rule joins the report, and the prompt holds the rule as data" do
      test = self()

      Theseus.LLM.Stub.reply(fn _system, [message] ->
        send(test, {:prompt, message.content})

        {:ok,
         ~s|```json\n[{"rule": "The total is never negative.", "matches": false, "why": "It allows -1."}]\n```|}
      end)

      {:ok, change, _} =
        Theseus.Changes.propose(proposal(intent: "loosen", spec_source: spec_with_loose_rule()))

      assert %{result: :info, detail: %{rules: [verdict]}} = wait_for_rules(change.id)

      assert verdict == %{
               rule: "The total is never negative.",
               matches: false,
               why: "It allows -1."
             }

      assert_received {:prompt, prompt}
      assert prompt =~ "<untrusted_data"
      assert prompt =~ "Rule: The total is never negative."
      assert prompt =~ "t >= -1"

      d =
        Theseus.Describe.change(
          elem(Theseus.Changes.get(change.id), 1),
          elem(Theseus.Changes.get(change.id), 2)
        )

      assert Enum.any?(d.stages, fn s ->
               Enum.any?(s.lines, &(&1 =~ "may not check this: It allows -1."))
             end)

      {:ok, _} = Theseus.Changes.reject(change.id, "test")
    end

    test "an unreadable answer is a skipped stage, never a decision" do
      Theseus.LLM.Stub.reply(fn _system, _messages -> {:ok, "I think so"} end)

      {:ok, change, _} =
        Theseus.Changes.propose(proposal(intent: "loosen", spec_source: spec_with_loose_rule()))

      assert %{result: :skip} = wait_for_rules(change.id)
      assert {:ok, %{status: status}, _} = Theseus.Changes.get(change.id)
      assert status in [:shadowing, :held]
      {:ok, _} = Theseus.Changes.reject(change.id, "test")
    end
  end
end
