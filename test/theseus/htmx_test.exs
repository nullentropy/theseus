defmodule Theseus.HtmxTest do
  @moduledoc "Endpoint units and htmx: request headers in, response headers out."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Describe, Outbox, Report, RouteMap, Version, Web}

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)
    :ok
  end

  defp get(path, headers) do
    headers
    |> Enum.reduce(Plug.Test.conn(:get, path), fn {k, v}, conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)
    |> Web.call(Web.init([]))
  end

  defp recorded_request do
    [%{args: [request]} | _] = Theseus.Traces.replay_set(Sample.Routes) |> Enum.reverse()
    request
  end

  test "an htmx request for part of a page carries its htmx headers; others do not" do
    Theseus.Traces.clear(Sample.Routes)

    conn =
      get("/people", [
        {"hx-request", "true"},
        {"hx-target", "people-rows"},
        {"hx-trigger", "more"},
        {"hx-current-url", "http://localhost:4000/people?page=2"},
        {"hx-prompt", String.duplicate("y", 300)},
        {"hx-trigger-name", "Zo%C3%AB"},
        {"hx-trigger-name-uri-autoencoded", "true"}
      ])

    assert Plug.Conn.get_resp_header(conn, "vary") == ["HX-Request"]

    assert recorded_request().htmx == %{
             target: "people-rows",
             trigger: "more",
             trigger_name: "Zoë",
             current_path: "/people?page=2",
             prompt: String.duplicate("y", 200)
           }

    # Boosted links and forms, history restores and plain requests want the
    # whole page.
    for headers <- [
          [{"hx-request", "true"}, {"hx-boosted", "true"}],
          [{"hx-request", "true"}, {"hx-history-restore-request", "true"}],
          []
        ] do
      Theseus.Traces.clear(Sample.Routes)
      get("/people", headers)
      refute Map.has_key?(recorded_request(), :htmx)
    end
  end

  test "the engine serves htmx itself, before any unit" do
    Theseus.Traces.clear(Sample.Routes)
    conn = get(Web.htmx_path(), [])

    assert conn.status == 200
    assert [type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert type =~ "text/javascript"

    assert Plug.Conn.get_resp_header(conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]

    assert byte_size(conn.resp_body) == 50_917
    assert conn.resp_body =~ ~s(version:"2.0.4")
    assert Theseus.Traces.replay_set(Sample.Routes) == []
  end

  test "a redirect that answers an htmx request becomes HX-Redirect" do
    htmx = %{method: "POST", htmx: %{target: "rows"}}
    hx = %{self: "/people/new"}

    conn = Web.respond(Plug.Test.conn(:post, "/"), Web.for_htmx({:redirect, "/people"}, htmx, hx))
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "hx-redirect") == ["/people"]
    assert Plug.Conn.get_resp_header(conn, "location") == []

    # Without htmx, or for a boosted form, it stays a redirect.
    assert Web.for_htmx({:redirect, "/people"}, %{method: "POST"}, nil) == {:redirect, "/people"}
    assert Web.for_htmx({:redirect, "/people"}, %{method: "POST"}, hx) == {:redirect, "/people"}

    # Inside headers the unit sets, too.
    conn =
      Web.respond(
        Plug.Test.conn(:post, "/"),
        Web.for_htmx({:htmx, %{trigger: "saved"}, {:redirect, "/people"}}, htmx, hx)
      )

    assert Plug.Conn.get_resp_header(conn, "hx-trigger") == ["saved"]
    assert Plug.Conn.get_resp_header(conn, "hx-redirect") == ["/people"]

    # Off the site, never.
    conn =
      Web.respond(Plug.Test.conn(:post, "/"), Web.for_htmx({:redirect, "//evil.com"}, htmx, hx))

    assert conn.status == 500
    assert conn.resp_body =~ "redirect must be a path on this site"
  end

  test "boosted links and forms: downloads, form errors and sign-in work" do
    hx = %{self: "/reports/access.csv?for=all"}
    csv = {200, {:download, "access.csv", "text/csv"}, "a,b\n"}

    # A download goes back as a plain navigation to the same address.
    assert Web.for_htmx(csv, %{method: "GET"}, hx) ==
             {:htmx, %{redirect: "/reports/access.csv?for=all"}, {200, :text, ""}}

    assert Web.for_htmx(csv, %{method: "GET"}, nil) == csv

    # A boosted form that answers with its errors keeps the address bar.
    errors = {422, :html, "<p>Name is required</p>"}
    assert Web.for_htmx(errors, %{method: "POST"}, hx) == {:htmx, %{push_url: false}, errors}
    assert Web.for_htmx(errors, %{method: "GET"}, hx) == errors

    # The engine's redirect to Google tells htmx to send the browser there.
    redirect = fn headers ->
      headers
      |> Enum.reduce(Plug.Test.conn(:get, "/auth/google"), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)
      |> Web.respond_external("https://accounts.google.com/o/oauth2/v2/auth?x=1")
    end

    conn = redirect.([{"hx-request", "true"}, {"hx-boosted", "true"}])
    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "hx-redirect") == [
             "https://accounts.google.com/o/oauth2/v2/auth?x=1"
           ]

    conn = redirect.([])
    assert conn.status == 302

    assert Plug.Conn.get_resp_header(conn, "location") == [
             "https://accounts.google.com/o/oauth2/v2/auth?x=1"
           ]
  end

  test "a unit sets htmx response headers, which are checked" do
    respond = &Web.respond(Plug.Test.conn(:get, "/"), &1)

    conn =
      respond.(
        {:htmx,
         %{
           trigger: %{"saved" => %{"name" => "Zoë"}},
           push_url: "/people?page=2",
           reswap: "outerHTML"
         }, {200, :html, "<tr><td>Zoë</td></tr>"}}
      )

    assert conn.status == 200
    assert conn.resp_body == "<tr><td>Zoë</td></tr>"
    assert Plug.Conn.get_resp_header(conn, "hx-push-url") == ["/people?page=2"]
    assert Plug.Conn.get_resp_header(conn, "hx-reswap") == ["outerHTML"]
    # Header values are ASCII: other text is escaped in the JSON.
    assert [trigger] = Plug.Conn.get_resp_header(conn, "hx-trigger")
    assert trigger == "{\"saved\":{\"name\":\"Zo" <> "\\" <> "u00eb\"}}"
    assert JSON.decode!(trigger) == %{"saved" => %{"name" => "Zoë"}}

    conn = respond.({:htmx, [refresh: true, push_url: false], {200, :text, ""}})
    assert Plug.Conn.get_resp_header(conn, "hx-refresh") == ["true"]
    assert Plug.Conn.get_resp_header(conn, "hx-push-url") == ["false"]

    for {headers, why} <- [
          {%{trigger: "saved\r\nset-cookie: x"}, "without line breaks"},
          {%{push_url: "https://evil.com/"}, "a path on this site"},
          {%{location: "/ok", hx_redirect: "/x"}, ":hx_redirect is not one of"},
          {%{refresh: "yes"}, "refresh is true"},
          {%{trigger: %{"saved" => {:tuple}}}, "must be JSON"},
          {["trigger"], "a map or a keyword list"}
        ] do
      conn = respond.({:htmx, headers, {200, :text, "x"}})
      assert conn.status == 500
      assert conn.resp_body =~ why
      assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
    end
  end

  test "messages inside htmx headers are sent, and the headers stay" do
    m1 = %{to: "a@acme.com", subject: "a", text: "a"}
    m2 = %{to: "b@acme.com", subject: "b", text: "b"}
    page = {200, :html, "<p>ok</p>"}

    assert Outbox.unwrap({:htmx, %{trigger: "x"}, {:send, [m1], page}}, []) ==
             {[m1], {:htmx, %{trigger: "x"}, page}}

    assert Outbox.unwrap({:send, [m1], {:htmx, %{trigger: "x"}, {:send, [m2], page}}}, []) ==
             {[m1, m2], {:htmx, %{trigger: "x"}, page}}
  end

  test "htmx headers the engine would refuse fail replay and show why" do
    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "GET", path: ["people"], htmx: %{target: "rows"}}),
            do: {:htmx, %{push_url: "https://elsewhere.example/"}, {200, :html, "<tr></tr>"}}

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    Theseus.Traces.clear(Sample.Routes)
    get("/people", [{"hx-request", "true"}, {"hx-target", "rows"}])

    {:ok, change, report} =
      Changes.check(
        proposal(
          unit: "Sample.Routes",
          unit_source: routes,
          intent: "people rows for htmx",
          behaviour_change: true
        )
      )

    assert %{name: :replay, detail: %{reason: reason}} = Report.failure(report)
    assert reason =~ "set htmx headers the engine refuses"
    assert reason =~ "push_url must be a path on this site"

    d = Describe.change(change, report)
    row = Enum.find(d.behaviour.changed, &(&1.call =~ "people"))
    assert row.after =~ "200 page \"\", with htmx headers the engine refuses: push_url"
  end

  test "the routes page marks routes that answer htmx" do
    {:ok, v} =
      Version.build(Demo.HtmxRoutes, """
      defmodule Demo.HtmxRoutes do
        use Theseus.Endpoint

        def handle(%{method: "GET", path: ["people"], htmx: %{target: "rows"}}), do: {200, :html, "<tr></tr>"}
        def handle(%{method: "GET", path: ["people"]}), do: {200, :html, "<table></table>"}
        def handle(_request), do: {404, %{}}
      end
      """)

    assert [
             %{path: "/people", htmx: true, who: nil},
             %{path: "/people", htmx: false, who: nil}
           ] = RouteMap.of_ast(Demo.HtmxRoutes, v.ast)
  end
end
