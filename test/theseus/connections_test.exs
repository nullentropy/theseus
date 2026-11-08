defmodule Theseus.ConnectionsTest do
  @moduledoc """
  Connecting a declared service, and the app's requests to services: the
  engine keeps the token and sends the requests, and the app gets the
  answers through fetched/1.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Theseus.TestHelpers

  alias Theseus.{Connections, FakeOAuth, Fetch}

  @routes_extra """
    def handle(%{method: "POST", path: ["sync"], body: body}),
      do: {:fetch, [%{service: "acme", domain: body["domain"], url: "https://api.example/v1/users", query: %{page: 1}, context: %{page: 1}}], {:redirect, "/"}}

    def handle(_request), do: {404, %{error: "not found"}}

    def sign_in(identity), do: {:ok, %{email: identity.email, domain: identity.domain}}

    def allow?(%{user: %{email: email}, domain: domain}),
      do: String.ends_with?(email, "@example.com") and domain in [nil, "example.com"]
    def allow?(_request), do: false

    def connection(%{event: :connected, domain: domain}),
      do: {:fetch, [%{service: "acme", domain: domain, url: "https://api.example/v1/users", query: %{page: 1}, context: %{page: 1}}], :ok}

    def connection(_event), do: :ok

    def fetched(%{status: 200, body: %{"next" => next}, request: %{context: %{page: n}} = request}) when is_integer(next),
      do: {:fetch, [%{request | query: %{"page" => next}, context: %{page: n + 1}}], :ok}

    def fetched(_response), do: :ok
  """

  setup_all do
    before = snapshot()

    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}\n",
        @routes_extra
      )

    approve_settled(
      unit: "Sample.Routes",
      intent: "routes for connection tests",
      unit_source: routes
    )

    unregister = FakeOAuth.register_services()
    {pid, base} = FakeOAuth.start()

    on_exit(fn ->
      Process.exit(pid, :normal)
      unregister.()
      restore(before)
    end)

    %{base: base}
  end

  setup %{base: base} do
    put_back = FakeOAuth.use(base)
    Theseus.Traces.clear(Sample.Routes)

    on_exit(fn ->
      for c <- Connections.list(), do: Connections.disconnect(c.service, c.domain, "test")
      Fetch.settle()
      put_back.()
    end)

    :ok
  end

  defp req(jar, method, path, opts \\ []) do
    conn = Plug.Test.conn(method, path, opts[:form])
    conn = Enum.reduce(jar, conn, fn {k, v}, c -> Plug.Test.put_req_cookie(c, k, v) end)
    conn = Theseus.Web.call(conn, Theseus.Web.init([]))

    jar =
      Enum.reduce(conn.resp_cookies, jar, fn
        {name, %{max_age: 0}}, jar -> Map.delete(jar, name)
        {name, %{value: value}}, jar -> Map.put(jar, name, value)
      end)

    {conn, jar}
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  # Goes to the service from `path` and comes back with `claims` and `tokens`.
  defp through(jar, path, claims_fun, tokens \\ %{}) do
    {conn, jar} = req(jar, :get, path)
    assert conn.status == 302, conn.resp_body
    query = URI.decode_query(URI.parse(location(conn)).query)
    code = "code-#{System.unique_integer([:positive])}"
    FakeOAuth.expect(code, query["code_challenge"], claims_fun.(query["nonce"]), tokens)

    {conn, jar} =
      req(
        jar,
        :get,
        "/auth/acme/callback?" <> URI.encode_query(code: code, state: query["state"])
      )

    {conn, jar, query}
  end

  defp signed_in(email) do
    {_conn, jar, _} = through(%{}, "/auth/acme", &FakeOAuth.claims(&1, %{"email" => email}))
    jar
  end

  defp grant(extra \\ %{}) do
    Map.merge(
      %{
        refresh_token: "refresh-#{System.unique_integer([:positive])}",
        scope: "openid email https://api.example/read"
      },
      extra
    )
  end

  defp csrf(jar) do
    conn =
      Enum.reduce(jar, Plug.Test.conn(:get, "/"), fn {k, v}, c ->
        Plug.Test.put_req_cookie(c, k, v)
      end)

    get_session(Theseus.SignIn.fetch(conn), "csrf")
  end

  defp calls(fun) do
    for %{fun: ^fun, args: [arg]} <- Enum.reverse(Theseus.Traces.list(Sample.Routes)), do: arg
  end

  # Waits for something the engine does in the background.
  defp eventually(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("it did not happen")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp connect(jar, tokens \\ grant()) do
    {conn, _, query} = through(jar, "/auth/acme/connect?next=/done", &FakeOAuth.claims/1, tokens)
    {conn, query}
  end

  test "an allowed admin connects, the app hears of it, and its requests carry the token, page after page" do
    FakeOAuth.answer("/v1/users", [
      {200, %{"users" => ["a", "b"], "next" => 2}},
      {200, %{"users" => ["c"]}}
    ])

    jar = signed_in("ada@example.com")
    {conn, query} = connect(jar)

    assert query["scope"] == "openid email https://api.example/read"
    assert query["access_type"] == "offline" and query["prompt"] == "consent"
    assert query["login_hint"] == "ada@example.com"
    assert {302, "/done"} = {conn.status, location(conn)}

    assert [%{service: "acme", domain: "example.com", connected_by: "ada@example.com"} = c] =
             Connections.list()

    assert c.scopes == ["openid", "email", "https://api.example/read"]
    refute Map.has_key?(c, :tokens)

    eventually(fn -> length(calls(:fetched)) == 2 end)

    assert [%{event: :connected, service: "acme", domain: "example.com", by: "ada@example.com"}] =
             calls(:connection)

    assert [%{query: %{"page" => "1"}} = first, %{query: %{"page" => "2"}}] = FakeOAuth.requests()
    assert first.authorization == "Bearer at-test"

    [one, two] = calls(:fetched)
    assert %{status: 200, body: %{"users" => ["a", "b"], "next" => 2}, error: nil} = one
    assert one.request.context == %{page: 1} and two.request.context == %{page: 2}
    assert two.body == %{"users" => ["c"]}
    refute inspect(one) =~ "at-test"
    assert [%{last_used: %{status: 200}}] = Connections.list()
  end

  test "a page's requests are sent after it answers" do
    FakeOAuth.answer("/v1/users", [{200, %{"users" => []}}])
    jar = signed_in("ada@example.com")
    connect(jar)
    eventually(fn -> length(calls(:fetched)) == 1 end)

    {conn, _} = req(jar, :post, "/sync", form: %{"domain" => "example.com", "_csrf" => csrf(jar)})
    assert {303, "/"} = {conn.status, location(conn)}
    eventually(fn -> length(calls(:fetched)) == 2 end)
  end

  test "an expired token is renewed first, and a 401 renews it and tries again" do
    %{refresh_token: refresh} = tokens = grant(%{expires_in: 0})
    FakeOAuth.refreshes(refresh, "at-fresh")
    FakeOAuth.answer("/v1/users", [{200, %{"users" => []}}])

    connect(signed_in("ada@example.com"), tokens)
    eventually(fn -> length(calls(:fetched)) == 1 end)
    assert [%{authorization: "Bearer at-fresh"}] = FakeOAuth.requests()

    FakeOAuth.reset()
    FakeOAuth.refreshes(refresh, "at-newer")
    FakeOAuth.answer("/v1/users", [{401, %{"error" => "expired"}}, {200, %{"users" => ["z"]}}])

    Fetch.take(
      {:fetch, [%{service: "acme", domain: "example.com", url: "https://api.example/v1/users"}],
       :ok},
      "test"
    )

    eventually(fn -> length(calls(:fetched)) == 2 end)

    assert [%{authorization: "Bearer at-fresh"}, %{authorization: "Bearer at-newer"}] =
             FakeOAuth.requests()

    assert %{status: 200, body: %{"users" => ["z"]}} = List.last(calls(:fetched))
  end

  test "requests the engine will not send come back to fetched/1 saying why" do
    requests = [
      %{service: "acme", domain: "example.com", url: "https://evil.example/v1/users"},
      %{service: "acme", domain: "example.com", url: "https://api.example/v1/../admin"},
      %{service: "acme", url: "https://api.example/v1/users"},
      %{service: "nobody", url: "https://api.example/v1/users"},
      %{service: "acme", domain: "other.org", url: "https://api.example/v1/users"},
      %{
        service: "acme",
        domain: "example.com",
        url: "https://api.example/v1/x",
        headers: %{"Authorization" => "mine"}
      },
      %{service: "open", url: "https://api.example/public/x", body: "raw"}
    ]

    Fetch.take({:fetch, requests, :ok}, "test")
    eventually(fn -> length(calls(:fetched)) == length(requests) end)

    errors = Enum.map(calls(:fetched), & &1.error) |> Enum.sort()

    expected = [
      "a request to acme names the domain whose connection to use",
      "a request's path may not have . or .. in it",
      "a text body needs a content-type header",
      "acme is not connected for example.com",
      "acme is not connected for other.org",
      "acme may only be sent requests under https://api.example/v1/",
      "the app declares no service nobody",
      "the engine sets the authorization header"
    ]

    # The service was never connected here, so both requests that named a
    # domain stop at the token; the URL check comes first for the others.
    assert Enum.all?(errors, &(&1 in expected)), inspect(errors)
    assert Enum.all?(calls(:fetched), &(&1.status == nil))
    assert FakeOAuth.requests() == []
  end

  test "a service without connect is sent no token, and a GET answered 503 is tried again" do
    FakeOAuth.answer("/public/status", [{503, %{"busy" => true}}, {200, "fine"}])

    Fetch.take(
      {:fetch, [%{service: "open", url: "https://api.example/public/status"}], :ok},
      "test"
    )

    eventually(fn -> length(calls(:fetched)) == 1 end)

    assert [%{authorization: nil}, %{authorization: nil}] = FakeOAuth.requests()
    assert [%{status: 200, body: "fine", error: nil}] = calls(:fetched)
  end

  test "a POST is sent once, with its JSON body" do
    FakeOAuth.answer("/public/notes", [{500, %{"oops" => true}}])

    Fetch.take(
      {:send, [],
       {:fetch,
        [
          %{
            service: "open",
            method: "post",
            url: "https://api.example/public/notes",
            body: %{"text" => "hi"}
          }
        ], :ok}},
      "test"
    )

    eventually(fn -> length(calls(:fetched)) == 1 end)

    assert [%{method: "POST", body: %{"text" => "hi"}, content_type: "application/json"}] =
             FakeOAuth.requests()

    assert [%{status: 500, body: %{"oops" => true}}] = calls(:fetched)
  end

  test "a node with requests turned off sends none" do
    Application.put_env(:theseus, :fetch, enabled: false)
    on_exit(fn -> Application.delete_env(:theseus, :fetch) end)

    assert :ok =
             Fetch.take(
               {:fetch, [%{service: "open", url: "https://api.example/public/x"}], :ok},
               "test"
             )

    Process.sleep(50)
    assert calls(:fetched) == [] and FakeOAuth.requests() == []
  end

  test "the app decides who may connect, and only accounts of an organization that grant the scopes connect" do
    {conn, _} = req(%{}, :get, "/auth/acme/connect")
    assert conn.status == 401

    {conn, _} = req(signed_in("bob@other.org"), :get, "/auth/acme/connect")
    assert conn.status == 403

    jar = signed_in("ada@example.com")

    {conn, _, _} =
      through(jar, "/auth/acme/connect", &(FakeOAuth.claims(&1) |> Map.delete("hd")), grant())

    assert conn.status == 401
    assert conn.resp_body =~ "not a personal one"

    {conn, _, _} =
      through(jar, "/auth/acme/connect", &FakeOAuth.claims/1, grant(%{scope: "openid email"}))

    assert conn.status == 401
    assert conn.resp_body =~ "was not granted to https://api.example/read"

    {conn, _, _} =
      through(jar, "/auth/acme/connect", &FakeOAuth.claims/1, %{
        scope: "openid email https://api.example/read"
      })

    assert conn.resp_body =~ "no refresh token"
    assert Connections.list() == []

    form = %{"domain" => "example.com", "_csrf" => csrf(jar)}
    {conn, _} = req(jar, :post, "/auth/acme/disconnect", form: Map.delete(form, "_csrf"))
    assert conn.status == 403
    {conn, _} = req(jar, :post, "/auth/acme/disconnect", form: form)
    assert conn.status == 404
  end

  test "connecting is asked again for the domain the service names, a replaced grant is revoked, and disconnecting revokes" do
    jar = signed_in("ada@example.com")
    other = grant()

    {conn, _, _} =
      through(
        jar,
        "/auth/acme/connect",
        &FakeOAuth.claims(&1, %{"email" => "ada@other.org", "hd" => "other.org"}),
        other
      )

    assert conn.status == 403
    assert conn.resp_body =~ "other.org"
    assert Connections.list() == []
    assert other.refresh_token in FakeOAuth.revoked()

    first = grant()
    connect(jar, first)
    second = grant()
    connect(jar, second)
    assert [%{domain: "example.com"}] = Connections.list()
    eventually(fn -> first.refresh_token in FakeOAuth.revoked() end)
    refute second.refresh_token in FakeOAuth.revoked()

    form = %{"domain" => "example.com", "_csrf" => csrf(jar), "next" => "/after"}
    {conn, _} = req(jar, :post, "/auth/acme/disconnect", form: form)
    assert {303, "/after"} = {conn.status, location(conn)}
    assert Connections.list() == []
    eventually(fn -> second.refresh_token in FakeOAuth.revoked() end)
    eventually(fn -> Enum.any?(calls(:connection), &(&1.event == :disconnected)) end)
  end

  test "connections survive a restart, encrypted" do
    dir = Path.expand("../../tmp/test_connections_#{System.unique_integer([:positive])}", __DIR__)
    path = Path.join(dir, "app.theseus.connections")
    Application.put_env(:theseus, :connections_file, true)
    Application.put_env(:theseus, :connections_path, path)

    restart = fn ->
      :ok = Supervisor.terminate_child(Theseus.Supervisor, Connections)
      {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, Connections)
    end

    on_exit(fn ->
      Application.put_env(:theseus, :connections_file, false)
      Application.delete_env(:theseus, :connections_path)
      restart.()
    end)

    restart.()
    jar = signed_in("ada@example.com")
    %{refresh_token: refresh} = tokens = grant()
    connect(jar, tokens)

    restart.()

    assert [%{service: "acme", domain: "example.com", connected_by: "ada@example.com"}] =
             Connections.list()

    refute File.read!(path) =~ refresh
  end
end
