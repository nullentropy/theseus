defmodule Theseus.EndpointTest do
  @moduledoc "The app's HTTP interface as an endpoint unit in the ledger."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Report, Version}
  alias Theseus.Validator.Static

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)
    :ok
  end

  defp request(method, path, body \\ nil) do
    conn = Plug.Test.conn(method, path, body && JSON.encode!(body))

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    conn = Theseus.Web.call(conn, Theseus.Web.init([]))
    {conn.status, conn.resp_body}
  end

  test "the app's routes come from the ledger" do
    assert Theseus.Web.endpoint() == Sample.Routes
    assert {404, ~s({"error":"not found"})} = request(:get, "/nope")
    assert {200, _} = request(:post, "/price", %{"items" => []})
  end

  test "a JSON body that is not an object reaches the endpoint as a map" do
    Theseus.Traces.clear(Sample.Routes)

    Plug.Test.conn(:post, "/nope", "[1, 2]")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Theseus.Web.call(Theseus.Web.init([]))

    assert [%{args: [%{body: %{"_json" => [1, 2]}}]}] = Theseus.Traces.replay_set(Sample.Routes)
  end

  test "an endpoint unit calls other units only through Theseus.call" do
    check = fn body ->
      {:ok, v} = Version.build(Demo.Routes, "defmodule Demo.Routes do\n#{body}\nend")
      Static.check(v, :endpoint, units: [Sample.Pricing])
    end

    assert :ok =
             check.("""
             use Theseus.Endpoint
             def handle(_req), do: {200, Theseus.call(Sample.Pricing, :total, [[], nil])}
             """)

    assert {:error, [violation]} =
             check.("""
             use Theseus.Endpoint
             def handle(_req), do: {200, Sample.Pricing.total([], nil)}
             """)

    assert violation =~ "call Sample.Pricing through Theseus.call"

    assert {:error, [violation]} =
             check.("""
             use Theseus.Endpoint
             def handle(_req), do: {200, Theseus.rollback(Sample.Pricing)}
             """)

    assert violation =~ "Theseus.rollback is not allowed"
  end

  test "a new unit and a route to it, both added by changes, answer over HTTP" do
    n = System.unique_integer([:positive])
    unit = "Toy.Halves#{n}"

    approve_settled(
      unit: unit,
      intent: "split an amount in two",
      unit_source: """
      defmodule #{unit} do
        def halves(cents) when is_integer(cents) and cents >= 0, do: [cents - div(cents, 2), div(cents, 2)]
      end
      """,
      spec_source: """
      defmodule #{unit}.Spec do
        use Theseus.Spec

        spec #{unit} do
          prose "Splits an amount of cents into two halves; the first gets the odd cent."
          example "an odd amount", halves: [5], expect: [3, 2]
        end
      end
      """
    )

    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "POST", path: ["halves"], body: %{"cents" => cents}}),
            do: {200, %{halves: Theseus.call(#{unit}, :halves, [cents])}}

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    {_change, report} =
      approve_settled(unit: "Sample.Routes", intent: "add POST /halves", unit_source: routes)

    assert %{result: :pass, detail: %{count: 4}} = Report.stage(report, :examples)
    assert %{result: :skip, detail: %{reason: reason}} = Report.stage(report, :shadow)
    assert reason =~ "it calls Sample.CouponStore, which a second run would call again"

    assert {200, ~s({"halves":[3,2]})} = request(:post, "/halves", %{"cents" => 5})
  end

  test "a server unit created by a change is started" do
    n = System.unique_integer([:positive])
    unit = "Toy.Counter#{n}"

    approve_settled(
      unit: unit,
      intent: "count calls",
      unit_source: """
      defmodule #{unit} do
        use GenServer
        def start_link(opts \\\\ []), do: GenServer.start_link(__MODULE__, 0, name: Keyword.get(opts, :name, __MODULE__))
        def next(server \\\\ __MODULE__), do: GenServer.call(server, :next)
        @impl true
        def init(n), do: {:ok, n}
        @impl true
        def handle_call(:next, _from, n), do: {:reply, n + 1, n + 1}
        @impl true
        def code_change(_old, n, _extra), do: {:ok, n}
      end
      """,
      spec_source: """
      defmodule #{unit}.Spec do
        use Theseus.Spec

        spec #{unit} do
          prose "Counts calls, starting at one."

          invariant "The first call returns 1 and the second 2.",
            check: fn call ->
              {:ok, s} = call.(:start_link, [[name: nil]])
              call.(:next, [s]) == 1 and call.(:next, [s]) == 2
            end
        end
      end
      """
    )

    module = Module.concat([unit])
    assert Theseus.call(module, :next, []) == 1
    assert Theseus.call(module, :next, []) == 2
  end

  test "a pure unit calls other pure units only through Theseus.call" do
    check = fn body ->
      {:ok, v} = Version.build(Demo.Rules, "defmodule Demo.Rules do\n#{body}\nend")
      Static.check(v, :pure, units: [Sample.Coupons])
    end

    assert :ok = check.("def f(c), do: Theseus.call(Sample.Coupons, :rule, [c])")
    assert {:error, [violation]} = check.("def f(c), do: Sample.Coupons.rule(c)")
    assert violation =~ "call Sample.Coupons through Theseus.call"

    assert {:error, [violation]} =
             check.("def f(r), do: Theseus.call(Sample.Routes, :handle, [r])")

    assert violation =~ "Sample.Routes is not on the allowlist"
  end

  test "a server unit calls pure units only, and only through Theseus.call" do
    check = fn body ->
      {:ok, v} = Version.build(Demo.Store, "defmodule Demo.Store do\nuse GenServer\n#{body}\nend")
      Static.check(v, :server, units: [Sample.Pricing])
    end

    code_change = "def code_change(_o, s, _e), do: {:ok, s}"

    assert :ok =
             check.("""
             def handle_call(:t, _f, s), do: {:reply, Theseus.call(Sample.Pricing, :total, [[], nil]), s}
             #{code_change}
             """)

    assert {:error, [violation]} =
             check.("""
             def handle_call(:t, _f, s), do: {:reply, Sample.Pricing.total([], nil), s}
             #{code_change}
             """)

    assert violation =~ "call Sample.Pricing through Theseus.call"

    assert {:error, [violation]} =
             check.("""
             def handle_call(:t, _f, s), do: {:reply, Theseus.call(Sample.Routes, :handle, [%{}]), s}
             #{code_change}
             """)

    assert violation =~ "Sample.Routes is neither allowed nor a pure unit on this branch"
  end

  test "a server unit keeps its rules in a pure unit, whose calls are recorded" do
    n = System.unique_integer([:positive])
    rules = "Toy.Rules#{n}"
    server = "Toy.Tally#{n}"

    approve_settled(
      unit: rules,
      intent: "counting rule",
      unit_source: "defmodule #{rules} do\n  def next(n) when is_integer(n), do: n + 2\nend\n",
      spec_source: """
      defmodule #{rules}.Spec do
        use Theseus.Spec

        spec #{rules} do
          prose "Counts in twos."
          example "from zero", next: [0], expect: 2
        end
      end
      """
    )

    approve_settled(
      unit: server,
      intent: "tally in twos",
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
          prose "Tallies in twos."

          invariant "The first bump gives 2 and the second 4.",
            check: fn call ->
              {:ok, s} = call.(:start_link, [[name: nil]])
              call.(:bump, [s]) == 2 and call.(:bump, [s]) == 4
            end
        end
      end
      """
    )

    assert Theseus.call(Module.concat([server]), :bump, []) == 2
    assert Theseus.call(Module.concat([server]), :bump, []) == 4
    recorded = Theseus.Traces.replay_set(Module.concat([rules]))
    assert Enum.map(recorded, & &1.args) |> Enum.sort() == [[0], [2]]
  end

  test "a download is sent as an attachment, with a safe name and only text types" do
    respond = &Theseus.Web.respond(Plug.Test.conn(:get, "/"), &1)

    conn =
      respond.({200, {:download, "access report.csv", "text/csv"}, "app,person\nFigma,bob\n"})

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="access_report.csv")
           ]

    assert [type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert type =~ "text/csv"
    assert conn.resp_body == "app,person\nFigma,bob\n"

    assert respond.({200, {:download, "x.html", "text/html"}, "<script>"}).status == 500
    assert respond.({200, {:download, "../.env", "text/plain"}, "x"}).status == 500
    assert respond.({200, {:download, ".env", "text/plain"}, "x"}).status == 500
  end

  test "app reaches a root that the same group creates" do
    n = System.unique_integer([:positive])
    root = "Toy.NewRoot#{n}"
    thing = "Toy.Thing#{n}"

    {:ok, results} =
      Changes.check_group(%{
        intent: "a new root in front of the old one",
        proposer: %{kind: :test, client: "test"},
        behaviour_change: true,
        units: [
          %{
            unit: root,
            unit_source: """
            defmodule #{root} do
              use Theseus.Endpoint
              def handle(%{path: ["new"]}), do: {200, %{new: true}}
              def handle(request), do: Theseus.call(Sample.Routes, :handle, [request])
            end
            """,
            spec_source: """
            defmodule #{root}.Spec do
              use Theseus.Spec

              spec #{root} do
                prose "Answers /new and hands the rest on."
                example "new", handle: [%{method: "GET", path: ["new"], query: %{}, body: %{}}], expect: {200, %{new: true}}
              end
            end
            """
          },
          %{
            unit: thing,
            unit_source: "defmodule #{thing} do\n  def name, do: \"thing\"\nend\n",
            spec_source: """
            defmodule #{thing}.Spec do
              use Theseus.Spec

              spec #{thing} do
                prose "A thing, and the app answers /new."

                invariant "The app answers /new.",
                  check: fn _call, app ->
                    app.(:handle, [%{method: "GET", path: ["new"], query: %{}, body: %{}}]) == {200, %{new: true}}
                  end
              end
            end
            """
          }
        ]
      })

    for {c, r} <- results, do: assert(r.passed, "#{c.unit}: #{inspect(Report.failure(r))}")
  end

  test "a root that drops a callback the engine calls fails replay unless the change says so" do
    with_tick =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        "  def handle(_request), do: {404, %{error: \"not found\"}}\n\n  def tick(_tick), do: {:ok, 0}"
      )

    approve_settled(
      unit: "Sample.Routes",
      unit_source: with_tick,
      intent: "tick",
      behaviour_change: true
    )

    post_price(%{"items" => []})

    tidy = fn keeps? ->
      Changes.check(
        proposal(
          unit: "Sample.Routes",
          unit_source: fixture("routes.ex"),
          intent: "tidy",
          behaviour_change: not keeps?
        )
      )
    end

    {:ok, _change, report} = tidy.(true)
    assert %{name: :replay, detail: %{reason: reason}} = Report.failure(report)
    assert reason =~ "no longer has tick/1, which the engine calls"

    {:ok, change, report} = tidy.(false)
    assert report.passed, inspect(Report.failure(report))

    lines =
      Enum.find(Theseus.Describe.change(change, report).stages, &(&1.name == "behaviour")).lines

    assert hd(lines) =~ "it no longer has tick/1, which the engine calls"
  end

  test "the root endpoint is the one that reaches all the others" do
    choose = &Theseus.Web.choose_root/2

    # A tree: the router hands on to admin and api.
    assert choose.(%{R: [:A, :P], A: [], P: []}, nil) == :R
    # Admin calls the router back: both reach everything; neither is
    # uncalled, so the previous root stays.
    assert choose.(%{R: [:A], A: [:R]}, :R) == :R
    # A new endpoint nothing calls yet does not take over.
    assert choose.(%{R: [:A], A: [:R], W: []}, :R) == :R
    assert choose.(%{R: [:A], A: [], B: []}, nil) == :R
    # A cycle below the root still leaves the root.
    assert choose.(%{R: [:A], A: [:P], P: [:A]}, nil) == :R
    # After a restart, in a cycle, the one that calls the most others wins.
    assert choose.(%{A: [:R], R: [:A, :P], P: []}, nil) == :R
    assert Theseus.Web.root_cycle(%{A: [:R], R: [:A, :P], P: []}) == [:A, :R]
    assert Theseus.Web.root_cycle(%{R: [:A], A: [:P], P: [:A]}) == nil
    assert Theseus.Web.root_cycle(%{A: [:R], R: [:A], W: []}) == [:A, :R]
    assert Theseus.Web.root_cycle(%{R: [:A, :P], A: [], P: [], W: []}) == nil
  end

  test "routes split across endpoint units: the root hands paths on" do
    n = System.unique_integer([:positive])
    sub = "Toy.SubRoutes#{n}"

    root =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{path: ["sub" | _]} = request), do: Theseus.call(#{sub}, :handle, [request])

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    {:ok, results} =
      Changes.propose_group(%{
        intent: "move /sub routes to their own endpoint unit",
        proposer: %{kind: :test, client: "test"},
        units: [
          %{
            unit: sub,
            unit_source: """
            defmodule #{sub} do
              use Theseus.Endpoint
              def handle(%{path: ["sub", name]}), do: {200, %{sub: name}}
              def handle(_request), do: {404, %{error: "no such sub"}}
            end
            """,
            spec_source: """
            defmodule #{sub}.Spec do
              use Theseus.Spec

              spec #{sub} do
                prose "Answers /sub/NAME with the name."
                example "a name", handle: [%{method: "GET", path: ["sub", "x"], query: %{}, body: %{}}], expect: {200, %{sub: "x"}}
              end
            end
            """
          },
          %{unit: "Sample.Routes", unit_source: root}
        ]
      })

    for {c, r} <- results, do: assert(r.passed, "#{c.unit}: #{inspect(Report.failure(r))}")
    [{first, _} | _] = results
    {first, _} = settle(first.id)
    {:ok, _} = Changes.approve(first.id)

    assert Theseus.Web.endpoint() == Sample.Routes
    assert {200, ~s({"sub":"abc"})} = request(:get, "/sub/abc")
    assert {404, ~s({"error":"no such sub"})} = request(:get, "/sub")
    assert {200, _} = request(:post, "/price", %{"items" => []})

    # A sub-endpoint's spec checks a flow through the root with `app`,
    # which reaches the proposed version of the sub-endpoint.
    {:ok, change, report} =
      Changes.check(%{
        unit: sub,
        intent: "shout names",
        proposer: %{kind: :test, client: "test"},
        behaviour_change: true,
        unit_source: """
        defmodule #{sub} do
          use Theseus.Endpoint
          def handle(%{path: ["sub", name]}), do: {200, %{sub: String.upcase(name)}}
          def handle(_request), do: {404, %{error: "no such sub"}}
        end
        """,
        spec_source: """
        defmodule #{sub}.Spec do
          use Theseus.Spec

          spec #{sub} do
            prose "Answers /sub/NAME with the name in capitals, through the app."

            invariant "The app answers /sub/x with X.",
              check: fn _call, app ->
                {200, %{sub: "X"}} == app.(:handle, [%{method: "GET", path: ["sub", "x"], query: %{}, body: %{}}])
              end
          end
        end
        """
      })

    assert report.passed, inspect(Report.failure(report))
    d = Theseus.Describe.change(change, report)
    assert "The app answers /sub/x with X." in d.spec_changes.live_unit_misses

    # The sub-endpoint calling the root back would leave no clear root.
    {:ok, _change, report} =
      Changes.check(%{
        unit: sub,
        intent: "call the root back",
        proposer: %{kind: :test, client: "test"},
        behaviour_change: true,
        unit_source: """
        defmodule #{sub} do
          use Theseus.Endpoint
          def handle(%{path: ["sub", name]}), do: {200, %{sub: name}}
          def handle(request), do: Theseus.call(Sample.Routes, :handle, [%{request | path: ["nope"]}])
        end
        """
      })

    assert %{name: :static, detail: %{violations: violations}} = Report.failure(report)
    assert [message] = violations[Module.concat([sub])]
    assert message =~ "would call each other, so no endpoint unit would clearly be the one"
  end

  test "recorded requests replay against a copy of the live server state" do
    :ok = Theseus.call(Sample.CouponStore, :deactivate, ["SAVE10"])
    on_exit(fn -> Theseus.call(Sample.CouponStore, :activate, ["SAVE10"]) end)

    Theseus.Traces.clear(Sample.Routes)

    basket = %{
      "items" => [%{"sku" => "a", "qty" => 4, "unit_cents" => 2500}],
      "coupon" => "SAVE10"
    }

    assert {200, %{"discount_cents" => 0}} = post_price(basket)

    routes =
      String.replace(
        fixture("routes.ex"),
        "{200, Theseus.call(Sample.Pricing, :total, [request.items, rule])}",
        "{200, Map.put(Theseus.call(Sample.Pricing, :total, [request.items, rule]), :note, \"v2\")}"
      )

    spec =
      String.replace(
        fixture("routes_spec.ex"),
        "%{subtotal_cents:",
        "%{note: \"v2\", subtotal_cents:"
      )

    {:ok, _change, report} =
      Changes.check(
        proposal(
          unit: "Sample.Routes",
          intent: "add a note",
          unit_source: routes,
          spec_source: spec
        )
      )

    assert report.passed, inspect(Report.failure(report))
    %{detail: %{traces: traces}} = Report.stage(report, :behaviour)

    assert [row] =
             Enum.filter(traces.changed, &match?([%{body: %{"coupon" => "SAVE10"}}], &1.args))

    # The fresh coupon store has SAVE10 active; the live one does not.
    assert {:ok, {200, %{discount_cents: 0}}} = row.before
    assert {:ok, {200, %{discount_cents: 0, note: "v2"}}} = row.after
  end

  test "before and after never share a server unit's state" do
    n = System.unique_integer([:positive])
    counter = "Toy.Clicks#{n}"

    approve_settled(
      unit: counter,
      intent: "count clicks",
      unit_source: """
      defmodule #{counter} do
        use GenServer
        def start_link(opts \\\\ []), do: GenServer.start_link(__MODULE__, 0, name: Keyword.get(opts, :name, __MODULE__))
        def click(server \\\\ __MODULE__), do: GenServer.call(server, :click)
        @impl true
        def init(n), do: {:ok, n}
        @impl true
        def handle_call(:click, _from, n), do: {:reply, n + 1, n + 1}
        @impl true
        def code_change(_old, n, _extra), do: {:ok, n}
      end
      """,
      spec_source: """
      defmodule #{counter}.Spec do
        use Theseus.Spec

        spec #{counter} do
          prose "Counts clicks."

          invariant "Clicks count up from one.",
            check: fn call ->
              {:ok, s} = call.(:start_link, [[name: nil]])
              call.(:click, [s]) == 1
            end
        end
      end
      """
    )

    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "POST", path: ["click"]}), do: {200, %{clicks: Theseus.call(#{counter}, :click, [])}}

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    approve_settled(unit: "Sample.Routes", intent: "count clicks", unit_source: routes)
    Theseus.Traces.clear(Sample.Routes)
    for _ <- 1..3, do: assert({200, _} = request(:post, "/click"))

    # Sample.Routes calls Sample.Pricing, so its recorded clicks are replayed
    # through both systems. Each must count from the same live state.
    {:ok, _change, report} =
      Changes.check(
        proposal(
          intent: "same",
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec()
        )
      )

    assert %{detail: %{units: [routes_entry]}} = Report.stage(report, :dependents)
    assert routes_entry.unit == Sample.Routes

    clicks =
      for %{fun: :handle, args: [%{path: ["click"]}]} <- Theseus.Traces.replay_set(Sample.Routes),
          do: 1

    assert length(clicks) == 3
    assert routes_entry.traces.counts.changed == 0
  end

  test "a recorded request that crashes a server unit does not stop a validation" do
    n = System.unique_integer([:positive])
    check = "Toy.OnlyInts#{n}"
    box = "Toy.IntBox#{n}"

    check_source = fn body -> "defmodule #{check} do\n  #{body}\nend\n" end

    approve_settled(
      unit: check,
      intent: "integers only",
      unit_source: check_source.("def check(x) when is_integer(x), do: x"),
      spec_source: """
      defmodule #{check}.Spec do
        use Theseus.Spec

        spec #{check} do
          prose "Takes integers."
          example "one", check: [1], expect: 1
        end
      end
      """
    )

    approve_settled(
      unit: box,
      intent: "hold a number",
      unit_source: """
      defmodule #{box} do
        use GenServer
        def start_link(opts \\\\ []), do: GenServer.start_link(__MODULE__, 0, name: Keyword.get(opts, :name, __MODULE__))
        def put(server \\\\ __MODULE__, x), do: GenServer.call(server, {:put, x})
        @impl true
        def init(n), do: {:ok, n}
        @impl true
        def handle_call({:put, x}, _from, _n), do: {:reply, :ok, Theseus.call(#{check}, :check, [x])}
        @impl true
        def code_change(_old, n, _extra), do: {:ok, n}
      end
      """,
      spec_source: """
      defmodule #{box}.Spec do
        use Theseus.Spec

        spec #{box} do
          prose "Holds a number."

          invariant "It takes a number.",
            check: fn call ->
              {:ok, s} = call.(:start_link, [[name: nil]])
              call.(:put, [s, 3]) == :ok
            end
        end
      end
      """
    )

    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "POST", path: ["box"], body: body}), do: {200, %{ok: Theseus.call(#{box}, :put, [body["x"]])}}

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    approve_settled(unit: "Sample.Routes", intent: "box route", unit_source: routes)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {500, _} = request(:post, "/box", %{"x" => "not a number"})
    end)

    # Replaying that request crashes the box on the sandbox, in both systems.
    {:ok, _change, report} =
      Changes.check(
        proposal(
          unit: check,
          intent: "also take floats",
          unit_source: check_source.("def check(x) when is_integer(x) or is_float(x), do: x")
        )
      )

    assert report.passed, inspect(Report.failure(report))
    assert %{detail: %{units: units}} = Report.stage(report, :dependents)
    assert Enum.any?(units, &(&1.unit == Sample.Routes))
  end

  test "the engine ticks the endpoint unit with the time and the previous tick's" do
    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(_request), do: {404, %{error: "not found"}}

          def tick(%{now: now, last: last}), do: {:ticked, now, last}
        """
        |> String.trim_trailing()
      )

    approve_settled(unit: "Sample.Routes", intent: "tick", unit_source: routes)

    {:ticked, first, _} = Theseus.Ticker.tick()
    {:ticked, second, last} = Theseus.Ticker.tick()
    assert last == first and DateTime.compare(second, first) != :lt

    assert Enum.any?(Theseus.Traces.replay_set(Sample.Routes), &(&1.fun == :tick))
  end

  test "a crash inside a unit called by the endpoint is reported once, by that unit" do
    test = self()
    id = "endpoint-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:theseus, :unit, :exception],
      fn _event, _m, meta, _ -> send(test, {:crashed, meta.unit}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert {500, _} = post_price(%{"items" => [%{"sku" => "ñ", "qty" => 1, "unit_cents" => 1}]})
    assert_receive {:crashed, Sample.Input}
    refute_receive {:crashed, Sample.Routes}, 100
  end
end
