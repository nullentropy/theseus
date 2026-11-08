defmodule Theseus.ReviewTest do
  @moduledoc "The review page: shows evidence without code; only a reviewer can approve."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)

    {:ok, change, _} =
      Theseus.Changes.propose(
        proposal(
          intent: "make free shipping apply from 5000 cents",
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec()
        )
      )

    settle(change.id)
    %{id: change.id}
  end

  defp get(path, cookie \\ nil) do
    conn = Plug.Test.conn(:get, path)
    conn = if cookie, do: Plug.Test.put_req_cookie(conn, "theseus_reviewer", cookie), else: conn
    Theseus.Admin.Router.call(conn, [])
  end

  defp post(path, params, cookie) do
    conn = Plug.Test.conn(:post, path, params)
    conn = if cookie, do: Plug.Test.put_req_cookie(conn, "theseus_reviewer", cookie), else: conn
    Theseus.Admin.Router.call(conn, [])
  end

  test "a change to a unit the root calls leads with what people see" do
    post_price(%{"items" => [%{"sku" => "a", "qty" => 1, "unit_cents" => 6000}]})

    {:ok, change, _} =
      Theseus.Changes.propose(
        proposal(
          intent: "cheaper shipping again",
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec()
        )
      )

    settle(change.id, fn -> post_price(%{"items" => []}) end)
    html = get("/changes/#{change.id}").resp_body
    assert html =~ "What people see"
    assert html =~ "Sample.Routes answers every request to the app"
    refute html =~ "Effect on Sample.Routes, which calls it"
  end

  test "the change page shows intent, evidence and spec changes, and no code", %{id: id} do
    html = get("/changes/#{id}").resp_body
    assert html =~ "make free shipping apply from 5000 cents"
    assert html =~ "New example: free shipping from 5000"
    assert html =~ "The total is never negative."
    refute html =~ "defmodule"
    refute html =~ "def total"
    refute html =~ "@free_shipping_from"
  end

  test "approve needs the reviewer token", %{id: id} do
    assert post("/changes/#{id}/approve", %{}, nil).status == 403
    assert post("/changes/#{id}/approve", %{}, "wrong").status == 403
    assert {:ok, %{status: :held}, _} = Theseus.Changes.get(id)

    assert post("/changes/#{id}/approve", %{}, Theseus.Review.token()).status == 303
    assert {:ok, %{status: :promoted}, _} = Theseus.Changes.get(id)
  end

  test "the reviewer link sets the cookie" do
    conn = get("/?token=#{Theseus.Review.token()}")
    assert conn.status == 303
    assert conn.resp_cookies["theseus_reviewer"].value == Theseus.Review.token()
    assert get("/?token=nope").status == 403
  end

  test "reject with a reason", %{id: id} do
    assert post("/changes/#{id}/reject", %{"reason" => "too generous"}, Theseus.Review.token()).status ==
             303

    assert {:ok, %{status: :rejected}, _} = Theseus.Changes.get(id)
    assert get("/units/Sample.Pricing").resp_body =~ "too generous"
  end

  test "the branches pages render, and making a branch live needs the reviewer token" do
    name = "rv#{System.unique_integer([:positive])}"
    :ok = Theseus.Branches.create(name)

    assert get("/branches").resp_body =~ name
    page = get("/branches/#{name}").resp_body
    assert page =~ "Forked from"
    assert page =~ "The same units and versions."

    assert post("/branches/#{name}/live", %{}, nil).status == 403
    assert Theseus.Branches.live() == "main"
  end

  test "the connections page renders without secrets" do
    html =
      Plug.Test.conn(:get, "/connections")
      |> Theseus.Admin.Router.call([])
      |> Map.fetch!(:resp_body)

    assert html =~ "<h2>Connections</h2>"
    refute html =~ "refresh"
  end

  test "a unit page says which units it calls and which call it" do
    html =
      Plug.Test.conn(:get, "/units/Sample.Pricing")
      |> Theseus.Admin.Router.call([])
      |> Map.fetch!(:resp_body)

    assert html =~ ~s(Calls nothing. Called by <a href="/units/Sample.Routes">Sample.Routes</a>.)
  end

  test "index and unit pages render" do
    assert get("/").resp_body =~ "Waiting for you"
    html = get("/units/Sample.Pricing").resp_body
    assert html =~ "Shipping is 599 cents"
    refute html =~ "defmodule"
  end

  test "page results show as their title and the text lines that differ, or say what else differs" do
    page = fn title, body ->
      "<!doctype html><html><head><title>#{title}</title><style>p{}</style></head><body><main><h1>#{title}</h1>#{body}</main></body></html>"
    end

    item = fn path, before, after_ ->
      %{
        fun: :handle,
        args: [%{path: [path]}],
        before: {:ok, before},
        after: {:ok, after_},
        class: :changed
      }
    end

    text_change =
      item.(
        "x",
        {200, :html, page.("Home", "<p>Hello, Ada!</p><p>Same &amp; kept</p>")},
        {200, :html, page.("Home", "<p>Hi, Ada!</p><p>Same &amp; kept</p>")}
      )

    styling_change =
      item.(
        "y",
        {200, :html, page.("Home", "<p>Hello</p>")},
        {200, :html, page.("Home", ~s(<p class="big">Hello</p>))}
      )

    form_change =
      item.(
        "z",
        {200, :html, page.("Home", ~s(<form action="/pay"><button>Pay</button></form>))},
        {200, :html,
         page.(
           "Home",
           ~s(<form action="https://elsewhere.example/pay"><button>Pay</button></form>)
         )}
      )

    fragment_change =
      %{
        fun: :home,
        args: [],
        before: {:ok, "<section><h1>Hello</h1><p>One</p></section>"},
        after: {:ok, "<section><h1>Hello</h1><p>Two</p></section>"},
        class: :changed
      }

    alias Theseus.PageText

    # Only classes, styles and whitespace count as styling.
    assert PageText.styling_only?({:ok, "<p>Hi</p>"}, {:ok, ~s(<p class="x">  Hi</p>)})
    refute PageText.styling_only?({:ok, "<p>Hi</p>"}, {:ok, "<p>Hello</p>"})
    refute PageText.styling_only?({:ok, "a < b"}, {:ok, "a  < b"})

    refute PageText.styling_only?(
             {:ok, ~s(<input name="n" value="10">)},
             {:ok, ~s(<input name="n" value="1000">)}
           )

    refute PageText.styling_only?({:ok, "<p>Hi</p>"}, {:ok, "<p>Hi</p><script>steal()</script>"})
    assert PageText.compare("<p>Hi</p>", "<p>Hi</p><script>steal()</script>") == :markup

    # Text that moves is a text difference, shown in order; so is a new title.
    balances = fn a, b -> "<td>Alice</td><td>#{a}</td><td>Bob</td><td>#{b}</td>" end

    assert {:text, [_ | _], [_ | _]} = PageText.compare(balances.(10, 20), balances.(20, 10))

    assert {:text, [], []} =
             PageText.compare(
               page.("One", ""),
               page.("Two", "") |> String.replace("<h1>Two</h1>", "<h1>One</h1>")
             )

    download_change =
      item.(
        "csv",
        {200, {:download, "access.csv", "text/csv"}, "app,person\nFigma,bob\nZoom,cy\n"},
        {200, {:download, "access.csv", "text/csv"}, "app,person\nFigma,bob\n"}
      )

    items = [styling_change, form_change, text_change, fragment_change, download_change]

    report = %Theseus.Report{
      change_id: "chg_x",
      passed: true,
      stages: [
        %{
          name: :behaviour,
          result: :info,
          detail: %{traces: Theseus.Validator.Behaviour.summary(items)},
          ms: 0
        }
      ]
    }

    change = %Theseus.Change{
      id: "chg_x",
      trigger: %{kind: :human, payload: nil, untrusted: false},
      proposer: %{kind: :test, client: nil},
      intent: "greet",
      unit: Sample.Routes,
      candidates: [],
      at: DateTime.utc_now()
    }

    d = Theseus.Describe.change(change, report)
    assert [line] = Enum.find(d.stages, &(&1.name == "behaviour")).lines
    assert line =~ "5 give a different result (1 of them only in styling)"

    # Styling-only differences are listed last.
    [form, row, fragment, download, styling] = d.behaviour.changed
    assert download.before == ~s(200 download "access.csv" (3 lines\))
    assert download.before_changed =~ "| Zoom,cy"
    assert download.after_changed == ~s(200 download "access.csv" (2 lines\))

    assert form.after_changed =~
             "the same visible text; links, forms, scripts or other markup differ"

    assert fragment.before == ~s(HTML starting "Hello")
    assert fragment.before_changed == ~s(HTML starting "Hello" | One)
    assert fragment.after_changed == ~s(HTML starting "Hello" | Two)
    assert row.before == ~s(200 page "Home")
    assert row.before_changed == ~s(200 page "Home" | Hello, Ada!)
    assert row.after_changed == ~s(200 page "Home" | Hi, Ada!)
    assert styling.after_changed =~ "the same page, only styling differs"
  end
end
