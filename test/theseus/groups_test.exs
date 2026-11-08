defmodule Theseus.GroupsTest do
  @moduledoc "Changes to several units made together, and the units that call a changed unit."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Describe, Report}

  @basket %{"items" => [%{"sku" => "g-1", "qty" => 2, "unit_cents" => 1000}]}

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)
    :ok
  end

  # Pricing with total/2 renamed to price/2, and its spec to match.
  defp renamed_pricing, do: String.replace(fixture("pricing.ex"), "def total(", "def price(")

  defp renamed_pricing_spec,
    do:
      fixture("pricing_spec.ex")
      |> String.replace(~r/\btotal: \[/, "price: [")
      |> String.replace("call.(:total,", "call.(:price,")

  defp routes_calling_price,
    do:
      String.replace(
        fixture("routes.ex"),
        "Theseus.call(Sample.Pricing, :total, [request.items, rule])",
        "Theseus.call(Sample.Pricing, :price, [request.items, rule])"
      )

  defp group(units, extra \\ %{}) do
    Map.merge(
      %{
        intent: "rename total to price",
        units: units,
        proposer: %{kind: :test, client: "test"}
      },
      extra
    )
  end

  test "a change that breaks a unit calling it fails at :dependents and names it" do
    post_price(@basket)

    {:ok, change, report} =
      Changes.check(
        proposal(
          intent: "rename",
          unit_source: renamed_pricing(),
          spec_source: renamed_pricing_spec()
        )
      )

    refute report.passed
    assert %{name: :dependents, detail: %{units: [routes]}} = Report.failure(report)
    assert routes.unit == Sample.Routes
    assert routes.failed != []

    d = Describe.change(change, report)
    assert [%{unit: "Sample.Routes", failed: [first | _]}] = d.dependents
    assert first =~ "UndefinedFunctionError"
    assert Enum.any?(d.stages, &(&1.name == "dependents" and &1.result == "fail"))
  end

  test "the same change with its caller passes as a group, and approving one approves both" do
    for _ <- 1..3, do: post_price(@basket)

    {:ok, results} =
      Changes.propose_group(
        group(
          [
            %{
              unit: "Sample.Pricing",
              unit_source: renamed_pricing(),
              spec_source: renamed_pricing_spec()
            },
            %{unit: "Sample.Routes", unit_source: routes_calling_price()}
          ],
          %{behaviour_change: false}
        )
      )

    assert [{pricing, p_report}, {routes, r_report}] = results
    assert pricing.group == routes.group and pricing.group != nil
    assert p_report.passed, inspect(Report.failure(p_report))
    assert r_report.passed, inspect(Report.failure(r_report))

    # Replaying the recorded requests through the new routes and pricing
    # gives the same responses. Recorded calls to total/2 are listed as
    # calls to a function that is gone, not as differences.
    assert %{result: :pass, detail: %{compared: n}} = Report.stage(r_report, :replay)
    assert n > 0
    # Every recorded call to pricing is to total/2, which is gone, so none
    # is run; the routes' replay above is what compares behaviour.
    assert %{result: :skip, detail: %{reason: reason}} = Report.stage(p_report, :replay)
    assert reason =~ "no longer has"
    d = Describe.change(pricing, p_report)
    assert d.behaviour.counts.removed > 0
    assert hd(d.behaviour.removed).after =~ "has no total/2"

    {pricing, _} = settle(pricing.id, fn -> post_price(@basket) end)
    {routes, _} = settle(routes.id)
    assert pricing.status == :held and routes.status == :held
    assert Describe.change(pricing, p_report).held_because =~ "approves together"

    html =
      Plug.Test.conn(:get, "/")
      |> Theseus.Admin.Router.call([])
      |> Map.fetch!(:resp_body)

    assert html =~ "and 1 more, together"
    assert html =~ "Sample.Pricing, Sample.Routes"

    page =
      Plug.Test.conn(:get, "/changes/#{routes.id}")
      |> Plug.Test.put_req_cookie("theseus_reviewer", Theseus.Review.token())
      |> Theseus.Admin.Router.call([])
      |> Map.fetch!(:resp_body)

    assert page =~ "Approve all 2 changes"
    assert page =~ "Made together with other changes"
    assert page =~ ~s(href="/groups/#{routes.group}")

    group_page =
      Plug.Test.conn(:get, "/groups/#{routes.group}")
      |> Plug.Test.put_req_cookie("theseus_reviewer", Theseus.Review.token())
      |> Theseus.Admin.Router.call([])
      |> Map.fetch!(:resp_body)

    assert group_page =~ "rename total to price"
    assert group_page =~ "2 changes made together"
    assert group_page =~ "Approve all 2 changes"
    # The root endpoint's replay leads, as what people see.
    assert group_page =~ "What people see"
    assert group_page =~ "Sample.Routes answers every request to the app"
    refute group_page =~ "Effect on Sample.Routes"
    assert group_page =~ "Spec changes"
    refute group_page =~ "defmodule"

    {:ok, approved} = Changes.approve(routes.id)
    assert approved.status == :promoted
    assert {:ok, %{status: :promoted}, _} = Changes.get(pricing.id)
    assert {200, %{"total_cents" => 2599}} = post_price(@basket)
  end

  test "a group whose member fails is rejected as a whole" do
    broken_spec = String.replace(renamed_pricing_spec(), "total_cents: 2599", "total_cents: 1")

    {:ok, results} =
      Changes.propose_group(
        group([
          %{unit: "Sample.Pricing", unit_source: renamed_pricing(), spec_source: broken_spec},
          %{unit: "Sample.Routes", unit_source: routes_calling_price()}
        ])
      )

    assert [{pricing, p_report}, {routes, _}] = results
    assert pricing.status == :rejected
    assert %{name: :examples} = Report.failure(p_report)
    assert routes.status == :rejected
    assert {200, _} = post_price(@basket)
  end

  test "a new unit and the route that uses it are validated as one system" do
    n = System.unique_integer([:positive])
    unit = "Toy.Greeting#{n}"

    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "GET", path: ["hello", name]}),
            do: {200, %{text: Theseus.call(#{unit}, :hello, [name])}}

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    routes_spec =
      String.replace(
        fixture("routes_spec.ex"),
        ~s(    example "other requests are not found",),
        """
            example "says hello",
              handle: [%{method: "GET", path: ["hello", "Ada"], query: %{}, body: %{}}],
              expect: {200, %{text: "Hello, Ada!"}}

            example "other requests are not found",
        """
        |> String.trim_trailing()
      )

    {:ok, results} =
      Changes.propose_group(
        group(
          [
            %{
              unit: unit,
              unit_source:
                "defmodule #{unit} do\n  def hello(name), do: \"Hello, \" <> name <> \"!\"\nend\n",
              spec_source: """
              defmodule #{unit}.Spec do
                use Theseus.Spec

                spec #{unit} do
                  prose "Greets people."
                  example "Ada", hello: ["Ada"], expect: "Hello, Ada!"
                end
              end
              """
            },
            %{unit: "Sample.Routes", unit_source: routes, spec_source: routes_spec}
          ],
          %{intent: "say hello"}
        )
      )

    for {c, r} <- results, do: assert(r.passed, "#{c.unit}: #{inspect(Report.failure(r))}")
    [{greeting, _}, {_routes, _}] = results
    {greeting, _} = settle(greeting.id)
    {:ok, _} = Changes.approve(greeting.id)

    conn = Plug.Test.conn(:get, "/hello/Grace") |> Theseus.Web.call(Theseus.Web.init([]))
    assert {200, ~s({"text":"Hello, Grace!"})} = {conn.status, conn.resp_body}
  end

  test "a group that created a unit removes it again when a later member fails to load" do
    n = System.unique_integer([:positive])
    unit = "Toy.Audit#{n}"
    module = Module.concat([unit])

    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "GET", path: ["audit"]}),
            do: {200, %{text: Theseus.call(#{unit}, :note, [])}}

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    audit = %{
      unit: unit,
      unit_source: "defmodule #{unit} do\n  def note, do: \"audited\"\nend\n",
      spec_source: """
      defmodule #{unit}.Spec do
        use Theseus.Spec

        spec #{unit} do
          prose "Says audited."
          example "note", note: [], expect: "audited"
        end
      end
      """
    }

    group_units = [audit, %{unit: "Sample.Routes", unit_source: routes}]

    {:ok, [{created, _}, {changed, _}]} =
      Changes.propose_group(group(group_units, %{intent: "audit", behaviour_change: true}))

    {created, _} = settle(created.id)
    {changed, _} = settle(changed.id)
    assert created.status == :held and changed.status == :held

    # Another version of the routes lands first, so the group's routes
    # change no longer applies to the live version.
    moved_on =
      String.replace(
        fixture("routes.ex"),
        ~s({404, %{error: "not found"}}),
        ~s({404, %{error: "no such page"}})
      )

    {:ok, version} = Theseus.Version.build(Sample.Routes, moved_on, current(Sample.Routes))
    {:ok, _} = Theseus.Loader.promote(version, actor: :system)

    assert {:error, _} = Changes.approve(created.id)
    assert :error = Theseus.Registry.fetch(module)
    assert :error = Theseus.Registry.fetch(Module.concat([unit, "Spec"]))
    refute Code.loaded?(module)
    refute Enum.any?(Theseus.Ledger.units(), &(&1.module == module))
    assert {:ok, %{status: :rejected}, _} = Changes.get(created.id)

    # The same unit can be proposed again.
    {:ok, again, report} = Changes.check(proposal(audit))
    assert report.passed, inspect(Report.failure(report))
    assert again.unit == module
  end

  test "a spec change in a group runs against the group's versions of the units it calls" do
    # A rule only the cheaper shipping gives: 6000 cents ships free.
    routes_spec =
      String.replace(
        fixture("routes_spec.ex"),
        ~s(    example "other requests are not found",),
        """
            example "free shipping from 5000",
              handle: [
                %{
                  method: "POST",
                  path: ["price"],
                  query: %{},
                  body: %{"items" => [%{"sku" => "a", "qty" => 1, "unit_cents" => 6000}]}
                }
              ],
              expect:
                {200, %{subtotal_cents: 6000, discount_cents: 0, shipping_cents: 0, total_cents: 6000}}

            example "other requests are not found",
        """
        |> String.trim_trailing()
      )

    pricing = %{
      unit: "Sample.Pricing",
      unit_source: cheaper_shipping_unit(),
      spec_source: cheaper_shipping_spec()
    }

    routes = %{unit: "Sample.Routes", spec_source: routes_spec}

    {:ok, results} =
      Changes.check_group(
        group([pricing, routes], %{intent: "cheaper shipping", behaviour_change: true})
      )

    for {c, r} <- results, do: assert(r.passed, "#{c.unit}: #{inspect(Report.failure(r))}")

    # On its own, the routes' new rule fails: the live pricing still charges
    # shipping.
    {:ok, _change, alone} =
      Changes.check(proposal(unit: "Sample.Routes", spec_source: routes_spec))

    refute alone.passed
    assert %{name: :examples} = Report.failure(alone)
  end

  test "a caller is checked against the spec its group proposes for it" do
    basket = fn shipping ->
      """
          example "a 6000 basket",
            handle: [
              %{
                method: "POST",
                path: ["price"],
                query: %{},
                body: %{"items" => [%{"sku" => "a", "qty" => 1, "unit_cents" => 6000}]}
              }
            ],
            expect:
              {200, %{subtotal_cents: 6000, discount_cents: 0, shipping_cents: #{shipping}, total_cents: #{6000 + shipping}}}

          example "other requests are not found",
      """
      |> String.trim_trailing()
    end

    spec_with =
      &String.replace(
        fixture("routes_spec.ex"),
        ~s(    example "other requests are not found",),
        basket.(&1)
      )

    # Live, the routes' spec pins that a 6000 basket pays shipping.
    approve_settled(unit: "Sample.Routes", intent: "pin shipping", spec_source: spec_with.(599))

    pricing = %{
      unit: "Sample.Pricing",
      unit_source: cheaper_shipping_unit(),
      spec_source: cheaper_shipping_spec()
    }

    # Alone, cheaper shipping breaks the routes' live rule.
    {:ok, _change, alone} = Changes.check(proposal(Map.to_list(pricing)))
    assert %{name: :dependents} = Report.failure(alone)

    # With the routes' spec updated in the same group, it passes.
    {:ok, results} =
      Changes.check_group(
        group([pricing, %{unit: "Sample.Routes", spec_source: spec_with.(0)}], %{
          intent: "cheaper shipping",
          behaviour_change: true
        })
      )

    for {c, r} <- results, do: assert(r.passed, "#{c.unit}: #{inspect(Report.failure(r))}")
  end

  test "a recorded call to a removed function changes neither side's state" do
    # Recorded: activate, then a check; the live store no longer has ZED.
    :ok = Theseus.call(Sample.CouponStore, :activate, ["ZED"])
    true = Theseus.call(Sample.CouponStore, :active?, ["ZED"])
    :ok = Theseus.call(Sample.CouponStore, :deactivate, ["ZED"])

    # The store without activate/2: replayed in order, the recorded activate
    # must not run on the live side alone, or active?("ZED") would differ.
    store =
      fixture("coupon_store.ex")
      |> String.replace(~r/  def activate\(store.*\n/, "")
      |> String.replace(~r/  def handle_call\(\{:activate.*\n/, "")

    spec =
      String.replace(
        fixture("coupon_store_spec.ex"),
        ~r/    invariant "An activated code.*?      end\n\n/s,
        ""
      )

    {:ok, change, report} =
      Changes.check(
        proposal(
          unit: "Sample.CouponStore",
          intent: "no more activating",
          unit_source: store,
          spec_source: spec,
          behaviour_change: true
        )
      )

    assert report.passed, inspect(Report.failure(report))
    d = Describe.change(change, report)
    assert d.behaviour.counts.removed > 0
    assert d.behaviour.counts.changed == 0, inspect(d.behaviour.changed)
  end

  test "approving a group waits until every change of it is held" do
    {:ok, [{pricing, _}, {routes, _}]} =
      Changes.propose_group(
        group([
          %{
            unit: "Sample.Pricing",
            unit_source: renamed_pricing(),
            spec_source: renamed_pricing_spec()
          },
          %{unit: "Sample.Routes", unit_source: routes_calling_price()}
        ])
      )

    # Pricing is pure, so it is compared with live calls first; routes is not.
    assert pricing.status == :shadowing
    assert routes.status == :held
    assert {:error, {:group_not_ready, [{id, :shadowing}]}} = Changes.approve(routes.id)
    assert id == pricing.id

    {:ok, _} = Changes.reject(routes.id, "not now")
    assert {:ok, %{status: :rejected}, _} = Changes.get(pricing.id)
  end

  test "a group whose server unit fails to load rolls back the rest" do
    counting = counting_coupon_store()

    # It cannot migrate a store holding BREAK, which is activated after the
    # shadow run and before approval.
    failing =
      String.replace(
        counting,
        "  def code_change(_old_vsn, %MapSet{} = codes, _extra), do: {:ok, %{codes: codes, uses: %{}}}",
        """
          def code_change(_old_vsn, %MapSet{} = codes, _extra) do
            if MapSet.member?(codes, "BREAK"), do: {:error, :not_today}, else: {:ok, %{codes: codes, uses: %{}}}
          end
        """
      )

    on_exit(fn -> Theseus.call(Sample.CouponStore, :deactivate, ["BREAK"]) end)

    pricing_before = current(Sample.Pricing)
    store_before = current(Sample.CouponStore)

    {:ok, [{pricing, _}, {store, _}]} =
      Changes.propose_group(
        group(
          [
            %{
              unit: "Sample.Pricing",
              unit_source: cheaper_shipping_unit(),
              spec_source: cheaper_shipping_spec()
            },
            %{unit: "Sample.CouponStore", unit_source: failing}
          ],
          %{intent: "cheaper shipping and counted coupons"}
        )
      )

    {pricing, _} = settle(pricing.id, fn -> post_price(@basket) end)
    {store, _} = settle(store.id, fn -> post_price(Map.put(@basket, "coupon", "SAVE10")) end)
    assert pricing.status == :held and store.status == :held

    :ok = Theseus.call(Sample.CouponStore, :activate, ["BREAK"])
    assert {:error, _} = Changes.approve(pricing.id)
    assert current(Sample.Pricing) == pricing_before
    assert current(Sample.CouponStore) == store_before
    assert {:ok, %{status: :rejected}, _} = Changes.get(pricing.id)
    assert {:ok, %{status: :rejected}, _} = Changes.get(store.id)
  end

  test "a server unit candidate that cannot take the live state fails its shadow run" do
    unable =
      String.replace(
        counting_coupon_store(),
        "  def code_change(_old_vsn, %MapSet{} = codes, _extra), do: {:ok, %{codes: codes, uses: %{}}}",
        "  def code_change(_old_vsn, %MapSet{}, _extra), do: {:error, :not_today}"
      )

    {:ok, change, report} =
      Changes.propose(
        proposal(unit: "Sample.CouponStore", intent: "count uses", unit_source: unable)
      )

    assert change.status == :rejected

    assert %{name: :shadow, detail: %{error: {:candidate_server, _, _}}} =
             Report.failure(report)
  end

  test "a server unit candidate that takes too long to take the live state fails its shadow run" do
    Application.put_env(:theseus, :shadow_migrate_ms, 20)
    on_exit(fn -> Application.delete_env(:theseus, :shadow_migrate_ms) end)

    slow =
      String.replace(
        counting_coupon_store(),
        "  def code_change(_old_vsn, %MapSet{} = codes, _extra), do: {:ok, %{codes: codes, uses: %{}}}",
        """
          def code_change(_old_vsn, %MapSet{} = codes, _extra) do
            busy = Enum.reduce(1..20_000_000, 0, &(&1 + &2))
            {:ok, %{codes: codes, uses: %{}, busy: busy}}
          end
        """
      )

    started = System.monotonic_time(:millisecond)

    {:ok, change, report} =
      Changes.propose(
        proposal(unit: "Sample.CouponStore", intent: "count uses", unit_source: slow)
      )

    assert change.status == :rejected

    assert %{name: :shadow, detail: %{error: {:candidate_server, :exit, why}}} =
             Report.failure(report)

    assert why =~ "took longer than 20 ms"

    assert Describe.text({:candidate_server, :exit, why}) =~
             "could not start from the live state: taking"

    # The live store was resumed and answers.
    assert Theseus.call(Sample.CouponStore, :active?, ["SAVE10"])
    assert System.monotonic_time(:millisecond) - started < 30_000
  end

  test "a server unit that calls a changed pure unit runs its spec against the new version" do
    n = System.unique_integer([:positive])
    rules = "Toy.Step#{n}"
    server = "Toy.Counter#{n}"

    rules_spec = fn step ->
      """
      defmodule #{rules}.Spec do
        use Theseus.Spec

        spec #{rules} do
          prose "Steps a count."
          example "from zero", next: [0], expect: #{step}
        end
      end
      """
    end

    approve_settled(
      unit: rules,
      intent: "step by one",
      unit_source: "defmodule #{rules} do\n  def next(n), do: n + 1\nend\n",
      spec_source: rules_spec.(1)
    )

    approve_settled(
      unit: server,
      intent: "count",
      unit_source: """
      defmodule #{server} do
        use GenServer
        def start_link(opts \\\\ []), do: GenServer.start_link(__MODULE__, 0, name: Keyword.get(opts, :name, __MODULE__))
        def bump(server \\\\ __MODULE__), do: GenServer.call(server, :bump)
        @impl true
        def init(n), do: {:ok, n}
        @impl true
        def handle_call(:bump, _from, n) do
          next = Theseus.call(#{rules}, :next, [n])
          {:reply, next, next}
        end
        @impl true
        def code_change(_old, n, _extra), do: {:ok, n}
      end
      """,
      spec_source: """
      defmodule #{server}.Spec do
        use Theseus.Spec

        spec #{server} do
          prose "Counts up by one."

          invariant "The first bump gives 1.",
            check: fn call ->
              {:ok, s} = call.(:start_link, [[name: nil]])
              call.(:bump, [s]) == 1
            end
        end
      end
      """
    )

    {:ok, _change, report} =
      Changes.check(
        proposal(
          unit: rules,
          intent: "step by two",
          unit_source: "defmodule #{rules} do\n  def next(n), do: n + 2\nend\n",
          spec_source: rules_spec.(2)
        )
      )

    assert %{name: :dependents, detail: %{units: [counter]}} = Report.failure(report)
    assert counter.unit == Module.concat([server])
    assert [%{name: "The first bump gives 1."}] = counter.failed
  end

  test "a candidate that calls another unit of its group is not shadowed" do
    coupons =
      String.replace(
        fixture("coupons.ex"),
        "def rule(_code), do: nil",
        "def rule(_code), do: nil\n  def none, do: nil"
      )

    pricing =
      String.replace(
        fixture("pricing.ex"),
        "  defp discount(_rule, _subtotal), do: 0",
        "  defp discount(_rule, _subtotal), do: if(Theseus.call(Sample.Coupons, :none, []), do: 1, else: 0)"
      )

    {:ok, [{c, c_report}, {p, p_report}]} =
      Changes.check_group(
        group([
          %{unit: "Sample.Coupons", unit_source: coupons},
          %{unit: "Sample.Pricing", unit_source: pricing}
        ])
      )

    assert c_report.passed and p_report.passed
    assert c.unit == Sample.Coupons and p.unit == Sample.Pricing
    assert %{result: :skip, detail: %{reason: reason}} = Report.stage(p_report, :shadow)
    assert reason =~ "calls other units that change with it"
    refute Report.stage(c_report, :shadow).detail.reason =~ "calls other units"
  end

  test "propose_change over MCP takes several units" do
    args = %{
      "intent" => "rename total to price",
      "units" => [
        %{
          "unit" => "Sample.Pricing",
          "unit_source" => renamed_pricing(),
          "spec_source" => renamed_pricing_spec()
        },
        %{"unit" => "Sample.Routes", "unit_source" => routes_calling_price()}
      ]
    }

    {200, checked} = modern("tools/call", %{"name" => "check_change", "arguments" => args})
    assert tool_text(checked) =~ "Check passed for all 2 units."

    {200, proposed} = modern("tools/call", %{"name" => "propose_change", "arguments" => args})
    text = tool_text(proposed)
    assert text =~ ~r/Group grp_[a-z0-9]+/
    assert text =~ "## Sample.Pricing"
    assert text =~ "## Sample.Routes"
  end
end
