defmodule Theseus.RemoveTest do
  @moduledoc "Removing units through changes, and undoing an approved group."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Ledger, Registry}

  @extra """
  defmodule Sample.Extra do
    def double(x), do: x * 2
  end
  """

  @extra_spec """
  defmodule Sample.Extra.Spec do
    use Theseus.Spec

    spec Sample.Extra do
      prose "Doubles a number."
      example "two", double: [1], expect: 2
    end
  end
  """

  setup do
    before = snapshot()

    on_exit(fn ->
      for m <- [Sample.Extra, Sample.Extra.Spec],
          match?({:ok, _}, Registry.fetch(m)),
          do: Theseus.Loader.unregister(m, actor: :system)

      restore(before)
    end)

    :ok
  end

  defp create_extra do
    approve_settled(
      unit: "Sample.Extra",
      intent: "a unit to remove",
      unit_source: @extra,
      spec_source: @extra_spec
    )
  end

  defp failure(report), do: Theseus.Report.failure(report)

  test "a unit nothing calls is removed with its spec once approved, and stays removed" do
    create_extra()

    {:ok, change, report} =
      Changes.propose(%{
        unit: "Sample.Extra",
        intent: "not needed",
        remove: true,
        proposer: %{kind: :test, client: "t"}
      })

    assert report.passed and change.status == :held
    assert Theseus.Describe.change(change, report).touches == ["removes it"]

    {:ok, _} = Changes.approve(change.id)
    assert Registry.fetch(Sample.Extra) == :error
    assert Registry.fetch(Sample.Extra.Spec) == :error
    refute Enum.any?(Ledger.units(), &(&1.module == Sample.Extra))
    assert {:ok, %{status: :promoted}, _} = Changes.get(change.id)
  end

  test "a unit still called is not removed, unless its callers stop in the same group" do
    {:ok, _change, report} = Changes.check(%{unit: "Sample.Input", intent: "x", remove: true})
    refute report.passed
    assert %{name: :static, detail: %{violations: v}} = failure(report)
    assert Enum.any?(v[Sample.Input], &(&1 =~ "Sample.Routes still refers to it"))

    assert {:error, msg} =
             Changes.check(%{unit: "Sample.Routes", intent: "x", remove: true})
             |> then(fn {:ok, _, r} -> {:error, inspect(failure(r))} end)

    assert msg =~ "root endpoint"

    assert {:error, msg} = Changes.check(%{unit: "Sample.Nope", intent: "x", remove: true})
    assert msg =~ "no unit Sample.Nope"

    assert {:error, msg} =
             Changes.check(%{unit: "Sample.Input", intent: "x", remove: true, unit_source: "x"})

    assert msg =~ "sends no source"
  end

  test "an approved group is undone in one step, and not twice" do
    create_extra()
    before_pricing = current(Sample.Pricing)

    {:ok, [{first, _} | _] = changes} =
      Changes.propose_group(%{
        intent: "cheaper shipping and a new unit",
        proposer: %{kind: :test, client: "t"},
        units: [
          %{
            unit: "Sample.Pricing",
            unit_source: cheaper_shipping_unit(),
            spec_source: cheaper_shipping_spec()
          },
          %{unit: "Sample.Extra", remove: true}
        ]
      })

    for {c, _} <- changes, do: settle(c.id)
    {:ok, _} = Changes.approve(first.id)
    assert current(Sample.Pricing) != before_pricing
    assert Registry.fetch(Sample.Extra) == :error

    assert :ok = Changes.undo_group(first.group)
    assert current(Sample.Pricing) == before_pricing
    assert {:ok, _} = Registry.fetch(Sample.Extra)
    assert {:ok, _} = Registry.fetch(Sample.Extra.Spec)
    assert Changes.undone?(first.group)
    assert {:error, "this group was already undone"} = Changes.undo_group(first.group)
  end

  test "a group is not undone while one of its units has changed since" do
    {:ok, change, _} =
      Changes.propose(
        proposal(
          intent: "a",
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec()
        )
      )

    settle(change.id)
    {:ok, _} = Changes.approve(change.id)

    {:ok, [{g, _} | _] = group} =
      Changes.propose_group(%{
        intent: "create a unit",
        proposer: %{kind: :test, client: "t"},
        units: [%{unit: "Sample.Extra", unit_source: @extra, spec_source: @extra_spec}]
      })

    for {c, _} <- group, do: settle(c.id)
    {:ok, _} = Changes.approve(g.id)

    other = String.replace(@extra, "x * 2", "2 * x")
    approve_settled(unit: "Sample.Extra", intent: "reorder", unit_source: other)

    assert {:error, why} = Changes.undo_group(g.group)
    assert why =~ "changed since this group: Sample.Extra"
    assert {:ok, _} = Registry.fetch(Sample.Extra)
  end
end
