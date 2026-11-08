defmodule Theseus.CombineTest do
  @moduledoc "Two edits of one unit from the same version, combined by function."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Combine, Version}

  defp ast(source) do
    {:ok, v} = Version.build(Sample.X, source)
    v.ast
  end

  defp combined(base, ours, theirs) do
    case Combine.asts(ast(base), ast(ours), ast(theirs)) do
      {:ok, merged} -> {:ok, Version.render(merged)}
      other -> other
    end
  end

  @base """
  defmodule Sample.X do
    @limit 10

    def a(x), do: x + 1

    @doc "b"
    def b(x) when x > 0, do: x
    def b(_x), do: 0

    defp c(x), do: x * 2
  end
  """

  describe "functions" do
    test "edits to different functions are both kept, in order" do
      ours = String.replace(@base, "x + 1", "x + 2")
      theirs = String.replace(@base, "x * 2", "x * 3")

      assert {:ok, merged} = combined(@base, ours, theirs)
      assert merged =~ "x + 2" and merged =~ "x * 3"
      assert merged == String.replace(ours, "x * 2", "x * 3") |> ast() |> Version.render()
    end

    test "a function only one side adds goes after the one it follows there" do
      ours = String.replace(@base, "@limit 10", "@limit 20")

      theirs =
        String.replace(
          @base,
          "  def a(x), do: x + 1\n",
          "  def a(x), do: x + 1\n\n  def a2(x), do: a(x) + 1\n"
        )

      assert {:ok, merged} = combined(@base, ours, theirs)
      assert merged =~ ~r/def a\(x\).*def a2\(x\).*def b/s
      assert merged =~ "@limit 20"
    end

    test "all clauses and the doc of a function are one part" do
      ours = String.replace(@base, ~s(@doc "b"), ~s(@doc "the b"))
      theirs = String.replace(@base, "def b(_x), do: 0", "def b(_x), do: -1")
      assert {:conflict, ["b/1"]} = combined(@base, ours, theirs)
    end

    test "the same edit on both sides is kept once; a removal on one side is kept" do
      ours = String.replace(@base, "x + 1", "x + 2")
      assert {:ok, merged} = combined(@base, ours, ours)
      assert merged == ast(ours) |> Version.render()

      theirs = String.replace(@base, "\n  defp c(x), do: x * 2\n", "\n")
      assert {:ok, merged} = combined(@base, ours, theirs)
      refute merged =~ "defp c"
      assert merged =~ "x + 2"
    end

    test "different edits to one function conflict" do
      ours = String.replace(@base, "x + 1", "x + 2")
      theirs = String.replace(@base, "x + 1", "x + 3")
      assert {:conflict, ["a/1"]} = combined(@base, ours, theirs)
    end
  end

  describe "specs" do
    @spec_base """
    defmodule Sample.X.Spec do
      use Theseus.Spec

      spec Sample.X do
        prose "Adds."
        example "one", a: [1], expect: 2
      end
    end
    """

    test "rules added on both sides are all kept" do
      ours =
        String.replace(
          @spec_base,
          ~s(example "one", a: [1], expect: 2),
          ~s(example "one", a: [1], expect: 2\n    example "two", a: [2], expect: 3)
        )

      theirs =
        String.replace(
          @spec_base,
          ~s(example "one", a: [1], expect: 2),
          ~s(example "one", a: [1], expect: 2\n    example "zero", a: [0], expect: 1)
        )

      {:ok, base_v} = Version.build(Sample.X.Spec, @spec_base)
      {:ok, ours_v} = Version.build(Sample.X.Spec, ours)
      {:ok, theirs_v} = Version.build(Sample.X.Spec, theirs)
      assert {:ok, merged} = Combine.asts(base_v.ast, ours_v.ast, theirs_v.ast)
      text = Version.render(merged)

      assert text =~ ~s(example "two") and text =~ ~s(example "zero") and
               text =~ ~s(example "one")
    end
  end

  describe "schema units" do
    @schema_base """
    defmodule Sample.X do
      use Theseus.Schema

      def tables, do: %{notes: %{columns: %{text: :text}, indexes: []}}
    end
    """

    test "tables, columns and indexes added on both sides are all kept" do
      ours =
        String.replace(
          @schema_base,
          "%{text: :text}, indexes: []",
          "%{text: :text, tag: {:text, null: true}}, indexes: [[:tag]]"
        )

      theirs =
        String.replace(
          @schema_base,
          "indexes: []}}",
          "indexes: []}, tags: %{columns: %{name: :text}}}"
        )

      assert {:ok, merged} = combined(@schema_base, ours, theirs)
      {:ok, tables} = Theseus.Schema.from_ast(ast(merged))
      assert Map.keys(tables) |> Enum.sort() == [:notes, :tags]
      assert Map.has_key?(tables.notes.columns, :tag)
      assert tables.notes.indexes == [[:tag]]
    end

    test "one column defined differently on both sides conflicts" do
      ours = String.replace(@schema_base, "%{text: :text}", "%{text: :text, n: :integer}")
      theirs = String.replace(@schema_base, "%{text: :text}", "%{text: :text, n: :text}")
      assert {:conflict, ["tables/0"]} = combined(@schema_base, ours, theirs)
    end
  end

  describe "after an approval" do
    setup do
      before = snapshot()
      Application.put_env(:theseus, :combine, enabled: true)

      on_exit(fn ->
        Application.put_env(:theseus, :combine, enabled: false)
        :ok = Combine.sync()
        restore(before)
      end)

      :ok
    end

    @pricing_cap "  defp discount({:percent, pct}, subtotal), do: div(subtotal * min(pct, 50), 100)"
    @pricing_quote "  def quote_shipping(subtotal), do: shipping(nil, subtotal)\n\n  defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)"

    defp rejection(id) do
      Enum.find_value(Theseus.Ledger.events(), fn
        %{body: {:rejected, ^id, reason}} -> reason
        _ -> nil
      end)
    end

    defp pricing_with(from, to), do: String.replace(fixture("pricing.ex"), from, to)

    defp held(source, intent) do
      {:ok, c, _} =
        Changes.propose(
          proposal(
            intent: intent,
            unit_source: source,
            behaviour_change: true,
            proposer: %{kind: :mcp, client: "agent", person: "ann@example.com"}
          )
        )

      {c, _} = settle(c.id)
      assert c.status == :held
      c
    end

    test "a held change to another function of the unit is combined with the approved one" do
      first =
        held(
          pricing_with(
            "  defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)",
            @pricing_cap
          ),
          "cap percent coupons at 50"
        )

      second =
        held(
          pricing_with(
            "  defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)",
            @pricing_quote
          ),
          "quote shipping"
        )

      {:ok, _} = Changes.approve(first.id)
      :ok = Combine.sync()

      assert {:ok, %{status: :rejected}, _} = Changes.get(second.id)
      why = rejection(second.id)
      assert why =~ "combined with #{first.id}"
      [new_id] = Regex.run(~r/chg_[a-z0-9]+$/, why)

      {combined, _} = settle(new_id)
      assert combined.status == :held
      assert combined.intent == "quote shipping"
      assert combined.proposer.person == "ann@example.com"
      assert combined.trigger.kind == :combined
      assert combined.trigger.payload == %{replaces: [second.id], onto: first.id}

      source = hd(combined.candidates).source
      assert source =~ "min(pct, 50)" and source =~ "def quote_shipping"

      {:ok, c, r} = Changes.get(new_id)
      html = Theseus.Admin.Router.call(Plug.Test.conn(:get, "/changes/#{new_id}"), []).resp_body
      assert html =~ "The engine made this change"
      assert Theseus.Describe.change(c, r).combined == %{replaces: [second.id], onto: first.id}

      {:ok, _} = Changes.approve(new_id)
      assert %{shipping_cents: 599} = Theseus.call(Sample.Pricing, :total, [[], nil])
      assert Theseus.call(Sample.Pricing, :quote_shipping, [100]) == 599
    end

    test "a merge combines a unit changed in different functions on both branches" do
      b = "c#{System.unique_integer([:positive])}"
      :ok = Theseus.Branches.create(b)

      cap =
        String.replace(
          fixture("pricing.ex"),
          "div(subtotal * pct, 100)",
          "div(subtotal * min(pct, 50), 100)"
        )

      {:ok, on_branch, _} =
        Changes.propose(
          proposal(branch: b, intent: "cap", unit_source: cap, behaviour_change: true)
        )

      {on_branch, _} = settle(on_branch.id)
      {:ok, _} = Changes.approve(on_branch.id)

      on_main =
        held(
          pricing_with(
            "  defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)",
            @pricing_quote
          ),
          "quote shipping"
        )

      {:ok, _} = Changes.approve(on_main.id)

      {:ok, merge} = Theseus.Branches.merge(b, "main")
      assert merge.conflicts == [] and merge.combined == [Sample.Pricing]
      assert [change] = merge.changes
      {change, _} = settle(change.id)
      assert change.status == :held
      {:ok, _} = Changes.approve(change.id)

      assert Theseus.call(Sample.Pricing, :quote_shipping, [100]) == 599

      assert %{discount_cents: 500} =
               Theseus.call(Sample.Pricing, :total, [
                 [%{qty: 1, unit_cents: 1000}],
                 {:percent, 80}
               ])

      assert %{status: :same} =
               Enum.find(Theseus.Branches.diff(b, "main"), &(&1.unit == Sample.Pricing))
    end

    test "list_units and get_unit say who else is changing a unit" do
      b = "o#{System.unique_integer([:positive])}"
      :ok = Theseus.Branches.create(b, "main", by: "bob@example.com")

      cap =
        String.replace(
          fixture("pricing.ex"),
          "div(subtotal * pct, 100)",
          "div(subtotal * min(pct, 50), 100)"
        )

      {:ok, c, _} = Changes.propose(proposal(branch: b, intent: "cap", unit_source: cap))
      {c, _} = settle(c.id)
      {:ok, _} = Changes.approve(c.id)

      waiting =
        held(
          pricing_with(
            "  defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)",
            @pricing_quote
          ),
          "quote shipping"
        )

      {:ok, text, %{units: units}} = Theseus.MCP.Tools.call("list_units", %{}, "t")

      assert text =~
               "others: #{waiting.id} is waiting, proposed by ann@example.com: quote shipping"

      assert text =~ "others: changed on branch #{b} (bob@example.com), not merged yet"
      # Earlier tests may leave other branches that changed it too.
      assert %{others: notes} = Enum.find(units, &(&1.unit == "Sample.Pricing"))
      assert "#{waiting.id} is waiting, proposed by ann@example.com: quote shipping" in notes

      {:ok, text, %{others: others}} =
        Theseus.MCP.Tools.call("get_unit", %{"unit" => "Sample.Pricing"}, "t")

      assert text =~ "## Others working on it"
      assert "changed on branch #{b} (bob@example.com), not merged yet" in others

      # From the branch, main's waiting change shows, and so does a change on main.
      {:ok, text, _} =
        Theseus.MCP.Tools.call("get_unit", %{"unit" => "Sample.Pricing", "branch" => b}, "t")

      assert text =~ "#{waiting.id} is waiting on branch main"
      {:ok, _} = Changes.approve(waiting.id)

      {:ok, text, _} =
        Theseus.MCP.Tools.call("get_unit", %{"unit" => "Sample.Pricing", "branch" => b}, "t")

      assert text =~ "changed on main since this branch was made"
    end

    test "a held change to the same function is rejected, saying which part" do
      first =
        held(
          pricing_with(
            "  defp discount({:percent, pct}, subtotal), do: div(subtotal * pct, 100)",
            @pricing_cap
          ),
          "cap at 50"
        )

      second =
        held(
          pricing_with("div(subtotal * pct, 100)", "div(subtotal * min(pct, 40), 100)"),
          "cap at 40"
        )

      {:ok, _} = Changes.approve(first.id)
      :ok = Combine.sync()
      assert {:ok, %{status: :rejected}, _} = Changes.get(second.id)
      why = rejection(second.id)
      assert why =~ "#{first.id} was approved first and changed the same parts (discount/2)"
    end
  end
end
