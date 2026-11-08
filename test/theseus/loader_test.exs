defmodule Theseus.LoaderTest do
  @moduledoc "Hot loading, rollback, traces, and rebuilding from the ledger file."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Ledger, Loader, Registry, Version}

  @basket %{"items" => [%{"sku" => "abc-1", "qty" => 3, "unit_cents" => 2000}]}

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)
    %{seed: current(Sample.Pricing)}
  end

  test "POST /price works" do
    assert {200, body} = post_price(Map.put(@basket, "coupon", "SAVE10"))

    assert body == %{
             "subtotal_cents" => 6000,
             "discount_cents" => 600,
             "shipping_cents" => 599,
             "total_cents" => 5999
           }
  end

  test "rollback restores the previous version from its stored beam", %{seed: seed} do
    {:ok, change, _} =
      Changes.propose(proposal(intent: "cheaper", unit_source: cheaper_shipping_unit()))

    settle(change.id)
    {:ok, _} = Changes.approve(change.id)
    assert {200, %{"shipping_cents" => 0}} = post_price(@basket)

    {:ok, back} = Theseus.rollback(Sample.Pricing)
    assert back.hash == seed
    assert {200, %{"shipping_cents" => 599}} = post_price(@basket)
    assert Sample.Pricing.module_info(:attributes)[:vsn] == [seed]
    assert {:error, :no_previous_version} = Theseus.rollback(Sample.Pricing)
  end

  test "calls are traced, and errors are traced and re-raised" do
    Theseus.Traces.clear(Sample.Input)
    {:ok, _} = Theseus.call(Sample.Input, :parse, [@basket])

    assert_raise FunctionClauseError, fn ->
      Theseus.call(Sample.Input, :parse, [
        %{"items" => [%{"sku" => "café", "qty" => 1, "unit_cents" => 1}]}
      ])
    end

    [failed, ok] = Theseus.Traces.list(Sample.Input)
    assert {:ok, {:ok, %{items: [%{sku: "ABC-1"}]}}} = ok.result
    assert {:error, %FunctionClauseError{}, [_ | _]} = failed.result
    assert failed.version == current(Sample.Input)

    assert_raise ArgumentError, ~r/spec/, fn ->
      Theseus.call(Sample.Pricing.Spec, :__spec__, [])
    end
  end

  test "Theseus modules can never be registered" do
    {:ok, v} = Version.build(Theseus.Gate, "defmodule Theseus.Gate do\nend")
    assert {:error, :theseus_modules_are_not_units} = Loader.register(v)
  end

  test "the ledger is one file, and a copy of it boots the same application elsewhere" do
    {:ok, change, _} =
      Changes.propose(
        proposal(
          intent: "cheaper",
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec()
        )
      )

    settle(change.id)
    {:ok, _} = Changes.approve(change.id)
    before = snapshot()
    original = Ledger.path()

    copy =
      Path.join(
        System.tmp_dir!(),
        "theseus_copy_#{System.unique_integer([:positive])}/app.theseus"
      )

    File.mkdir_p!(Path.dirname(copy))
    File.cp!(original, copy)
    # A torn record at the end, as if the copy was taken mid-write.
    File.write!(copy, <<0, 0, 1, 0, 1, 2, 3>>, [:append])

    restart_on(copy, Map.keys(before))

    assert Ledger.path() == copy
    assert File.stat!(copy).size == File.stat!(original).size
    assert snapshot() == before

    for {module, hash} <- before do
      assert module.module_info(:attributes)[:vsn] == [hash]
    end

    assert {200, %{"shipping_cents" => 0}} = post_price(@basket)
    assert Theseus.rebuild() == Map.new(before, fn {m, h} -> {m, {:ok, h}} end)
    assert {:ok, %{status: :promoted}, _} = Changes.get(change.id)

    restart_on(original, Map.keys(before))
    assert snapshot() == before
  end

  test "a pure unit's old code is purged after the drain window" do
    source = fn n ->
      """
      defmodule TestUnits.Slow do
        def wait, do: receive(do: (:never -> #{n}))
      end
      """
    end

    {:ok, v0} = Version.build(TestUnits.Slow, source.(0))

    case Loader.register(v0, kind: :pure) do
      {:ok, _} -> :ok
      {:error, :already_registered} -> :ok
    end

    {:ok, v1} =
      Version.build(
        TestUnits.Slow,
        source.(System.unique_integer([:positive])),
        current(TestUnits.Slow)
      )

    {:ok, _} = Loader.promote(v1)
    stuck = spawn(fn -> apply(TestUnits.Slow, :wait, []) end)
    ref = Process.monitor(stuck)
    Process.sleep(20)

    # The stuck process is in what becomes old code. The next promote purges it.
    {:ok, v2} =
      Version.build(
        TestUnits.Slow,
        source.(System.unique_integer([:positive])),
        current(TestUnits.Slow)
      )

    {:ok, _} = Loader.promote(v2)

    {:ok, v3} =
      Version.build(
        TestUnits.Slow,
        source.(System.unique_integer([:positive])),
        current(TestUnits.Slow)
      )

    {:ok, _} = Loader.promote(v3)

    assert_receive {:DOWN, ^ref, :process, ^stuck, :killed}, 2000
    assert TestUnits.Slow.module_info(:attributes)[:vsn] == [v3.hash]
  end

  defp restart_on(path, modules) do
    :ok = Application.stop(:theseus)

    # A fresh VM has none of the ledger's modules loaded.
    for m <- modules do
      :code.purge(m)
      :code.delete(m)
      :code.purge(m)
    end

    Application.put_env(:theseus, :ledger_path, path)
    {:ok, _} = Application.ensure_all_started(:theseus)
    assert Registry.all() != []
  end
end
