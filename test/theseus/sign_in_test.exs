defmodule Theseus.SignInTest do
  @moduledoc "Sign-in with a declared service and dev sign-in, sessions, CSRF and redirects."

  use ExUnit.Case, async: false

  import Plug.Conn
  import Theseus.TestHelpers

  alias Theseus.FakeOAuth

  @routes_extra """
    def handle(%{method: "GET", path: ["me"], user: user, csrf_token: csrf, now: now}),
      do: {200, %{user: user, csrf: is_binary(csrf), now: is_struct(now, DateTime)}}

    def handle(%{method: "POST", path: ["me", "note"], body: body}), do: {200, %{saved: body["text"]}}

    def handle(%{method: "GET", path: ["private"], user: nil}), do: {:redirect, "/login"}

    def handle(%{method: "GET", path: ["away"]}), do: {:redirect, "//elsewhere.example/"}

    def handle(_request), do: {404, %{error: "not found"}}

    def sign_in(%{email: email} = identity) do
      if String.ends_with?(email, "@blocked.example"),
        do: {:error, {403, :html, "<p>Not here, " <> Plug.HTML.html_escape(identity.first_name) <> ".</p>"}},
        else:
            {:ok,
             %{
               email: email,
               first_name: identity.first_name,
               provider: identity.provider,
               domain: identity.domain,
               timed: is_struct(identity.now, DateTime)
             }}
    end
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
      intent: "routes for sign-in tests",
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
    config = Application.get_env(:theseus, :sign_in, [])
    put_back = FakeOAuth.use(base)

    on_exit(fn ->
      Application.put_env(:theseus, :sign_in, config)
      put_back.()
    end)

    :ok
  end

  defp put_sign_in(key, value) do
    Application.put_env(
      :theseus,
      :sign_in,
      Keyword.put(Application.get_env(:theseus, :sign_in), key, value)
    )
  end

  # A request with a cookie jar. Returns {conn, jar}.
  defp req(jar, method, path, opts \\ []) do
    conn =
      case opts[:json] do
        nil ->
          Plug.Test.conn(method, path, opts[:form])

        json ->
          Plug.Test.conn(method, path, JSON.encode!(json))
          |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(jar, conn, fn {k, v}, c -> Plug.Test.put_req_cookie(c, k, v) end)
    conn = Enum.reduce(opts[:headers] || [], conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    conn = if ip = opts[:remote_ip], do: %{conn | remote_ip: ip}, else: conn
    conn = %{conn | host: opts[:host] || "localhost"}
    conn = Theseus.Web.call(conn, Theseus.Web.init([]))

    jar =
      Enum.reduce(conn.resp_cookies, jar, fn {name, cookie}, jar ->
        case cookie do
          %{max_age: 0} -> Map.delete(jar, name)
          %{value: value} -> Map.put(jar, name, value)
        end
      end)

    {conn, jar}
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  defp json(conn), do: JSON.decode!(conn.resp_body)

  # Runs the service's flow up to the callback. Returns {callback conn, jar}.
  defp acme(claims_fun, opts \\ []) do
    {conn, jar} = req(%{}, :get, "/auth/acme" <> Keyword.get(opts, :query, ""))
    assert conn.status == 302
    url = URI.parse(location(conn))
    query = URI.decode_query(url.query)
    code = "code-#{System.unique_integer([:positive])}"
    FakeOAuth.expect(code, query["code_challenge"], claims_fun.(query["nonce"]))
    state = Keyword.get(opts, :state, query["state"])
    req(jar, :get, "/auth/acme/callback?" <> URI.encode_query(code: code, state: state))
  end

  test "without a client id, /auth/NAME says how to set it up" do
    Application.put_env(:theseus, :clients, %{})
    {conn, _} = req(%{}, :get, "/auth/acme")
    assert conn.status == 503
    assert conn.resp_body =~ "ACME_CLIENT_ID"
    assert conn.resp_body =~ "http://localhost:4000/auth/acme/callback"
  end

  test "a service the app does not declare, or one that does not sign people in, is the app's path" do
    for path <- ["/auth/nobody", "/auth/open", "/auth/open/connect"] do
      {conn, _} = req(%{}, :get, path)
      assert conn.status == 404, path
    end
  end

  test "sign-in sets a session the endpoint sees as request.user" do
    {conn, _} = req(%{}, :get, "/auth/acme?next=/private&login_hint=ada@example.com")
    url = URI.parse(location(conn))
    query = URI.decode_query(url.query)
    assert url.host == "accounts.example"

    assert %{
             "client_id" => "test-client",
             "redirect_uri" => "http://localhost:4000/auth/acme/callback",
             "response_type" => "code",
             "scope" => "openid email profile",
             "prompt" => "select_account",
             "code_challenge_method" => "S256",
             "login_hint" => "ada@example.com"
           } = query

    {conn, jar} = acme(&FakeOAuth.claims/1, query: "?next=/private")
    assert conn.status == 302
    assert location(conn) == "/private"

    {conn, _} = req(jar, :get, "/me")

    assert %{
             "user" => %{
               "email" => "ada@example.com",
               "first_name" => "Ada",
               "provider" => "acme",
               "domain" => "example.com"
             },
             "csrf" => true,
             "now" => true
           } = json(conn)

    {conn, _} = req(%{}, :get, "/me")
    assert %{"user" => nil, "csrf" => false} = json(conn)
  end

  test "the session cookie is encrypted and http-only" do
    {conn, jar} = acme(&FakeOAuth.claims/1)
    cookie = conn.resp_cookies["_theseus_session"]
    assert cookie.http_only
    assert cookie.same_site == "Lax"
    raw = jar["_theseus_session"]
    refute raw =~ "ada"

    decoded =
      raw
      |> String.split(".")
      |> Enum.map(&(Base.url_decode64(&1, padding: false) |> elem(1)))
      |> Enum.join()

    refute decoded =~ "ada"
  end

  test "a wrong state, nonce, audience, issuer or expiry signs nobody in" do
    {conn, jar} = acme(&FakeOAuth.claims/1, state: "forged")
    assert conn.status == 400
    {conn, _} = req(jar, :get, "/me")
    assert json(conn)["user"] == nil

    for {extra, message} <- [
          {%{"nonce" => "other"}, "does not belong to this sign-in"},
          {%{"aud" => "another-client"}, "issued for another client"},
          {%{"iss" => "https://evil.example"}, "not issued by acme"},
          {%{"exp" => System.os_time(:second) - 10}, "has expired"},
          {%{"email_verified" => false}, "not verified"}
        ] do
      {conn, jar} = acme(fn nonce -> FakeOAuth.claims(nonce) |> Map.merge(extra) end)
      assert conn.status == 401, message
      assert conn.resp_body =~ message
      {conn, _} = req(jar, :get, "/me")
      assert json(conn)["user"] == nil
    end
  end

  test "a callback without a started sign-in, or with an error from the service, is refused" do
    {conn, _} = req(%{}, :get, "/auth/acme/callback?code=x&state=y")
    assert conn.status == 400
    assert conn.resp_body =~ "expired"

    {conn, jar} = req(%{}, :get, "/auth/acme")
    assert conn.status == 302
    {conn, _} = req(jar, :get, "/auth/acme/callback?error=access_denied")
    assert conn.status == 401
    assert conn.resp_body =~ "access_denied"
  end

  test "the domain is the service's domain claim, and nil without it" do
    {_conn, jar} =
      acme(&FakeOAuth.claims(&1, %{"hd" => "Example.COM", "email" => "x@example.com"}))

    {conn, _} = req(jar, :get, "/me")
    assert json(conn)["user"]["domain"] == "example.com"

    {_conn, jar} = acme(&(FakeOAuth.claims(&1) |> Map.delete("hd")))
    {conn, _} = req(jar, :get, "/me")
    assert json(conn)["user"]["domain"] == nil
  end

  test "the app's sign_in/1 can turn someone away with its own page" do
    {conn, jar} =
      acme(&FakeOAuth.claims(&1, %{"email" => "eve@blocked.example", "given_name" => "<Eve>"}))

    assert conn.status == 403
    assert conn.resp_body == "<p>Not here, &lt;Eve&gt;.</p>"
    {conn, _} = req(jar, :get, "/me")
    assert json(conn)["user"] == nil
  end

  test "signed-in requests that change something need the CSRF token" do
    {_conn, jar} = acme(&FakeOAuth.claims/1)
    {conn, _} = req(jar, :post, "/me/note", json: %{"text" => "hi"})
    assert conn.status == 403

    {conn, _} = req(jar, :post, "/me/note", json: %{"text" => "hi", "_csrf" => "wrong"})
    assert conn.status == 403

    token =
      Plug.Conn.get_session(
        Theseus.SignIn.fetch(Plug.Test.conn(:get, "/") |> cookies(jar)),
        "csrf"
      )

    {conn, _} = req(jar, :post, "/me/note", json: %{"text" => "hi", "_csrf" => token})
    assert {200, %{"saved" => "hi"}} = {conn.status, json(conn)}

    {conn, _} =
      req(jar, :post, "/me/note", json: %{"text" => "hi"}, headers: [{"x-csrf-token", token}])

    assert conn.status == 200

    # Not signed in: nothing to forge, so no token is needed.
    {conn, _} = req(%{}, :post, "/me/note", json: %{"text" => "hi"})
    assert conn.status == 200
  end

  defp cookies(conn, jar),
    do: Enum.reduce(jar, conn, fn {k, v}, c -> Plug.Test.put_req_cookie(c, k, v) end)

  test "sign-out needs the CSRF token and ends the session" do
    {_conn, jar} = acme(&FakeOAuth.claims/1)

    token =
      Plug.Conn.get_session(
        Theseus.SignIn.fetch(Plug.Test.conn(:get, "/") |> cookies(jar)),
        "csrf"
      )

    {conn, jar} = req(jar, :post, "/auth/logout", form: %{})
    assert conn.status == 403
    {conn, _} = req(jar, :get, "/me")
    assert json(conn)["user"]

    {conn, jar} = req(jar, :post, "/auth/logout", form: %{"_csrf" => token, "next" => "/bye"})
    assert {303, "/bye"} = {conn.status, location(conn)}
    {conn, _} = req(jar, :get, "/me")
    assert json(conn)["user"] == nil
  end

  test "sessions end after session_hours" do
    {_conn, jar} = acme(&FakeOAuth.claims/1)
    put_sign_in(:session_hours, 0)
    Process.sleep(1_100)
    {conn, _} = req(jar, :get, "/me")
    assert json(conn)["user"] == nil
  end

  test "a sign-in started on another local name for this machine starts again on the public URL's host" do
    conn =
      Plug.Test.conn(:get, "/auth/acme?next=/me")
      |> Map.put(:host, "127.0.0.1")
      |> Theseus.Web.call(Theseus.Web.init([]))

    assert {302, "http://localhost:4000/auth/acme?next=/me"} = {conn.status, location(conn)}
  end

  test "with an idle limit, a session ends after that long without a request" do
    {_conn, jar} = acme(&FakeOAuth.claims/1)
    put_sign_in(:idle_minutes, 1)

    # Pretend the last request was two minutes ago.
    conn =
      Enum.reduce(jar, Plug.Test.conn(:get, "/"), fn {k, v}, c ->
        Plug.Test.put_req_cookie(c, k, v)
      end)

    conn = Theseus.SignIn.fetch(conn)
    conn = put_session(conn, "seen", System.os_time(:second) - 120) |> send_resp(200, "")
    jar = Map.put(jar, "_theseus_session", conn.resp_cookies["_theseus_session"].value)

    {conn, _} = req(jar, :get, "/me")
    assert json(conn)["user"] == nil
  end

  test "redirects stay on this site" do
    for path <- ["//evil.example", "/\t/evil.example", "/\\evil.example", "/a\r\nb"],
        do: assert(Theseus.SignIn.local_path(path) == nil, inspect(path))

    {conn, _} = acme(&FakeOAuth.claims/1, query: "?next=/%09/evil.example")
    assert location(conn) == "/"

    # Values that are not strings count as missing, not as errors.
    {conn, _} = req(%{}, :get, "/auth/acme/callback?state[]=x&code[a]=b")
    assert conn.status == 400

    {conn, _} = req(%{}, :get, "/private")
    assert {302, "/login"} = {conn.status, location(conn)}

    {conn, _} = req(%{}, :get, "/away")
    assert conn.status == 500

    {conn, _} = acme(&FakeOAuth.claims/1, query: "?next=//elsewhere.example/")
    assert location(conn) == "/"
  end

  test "dev sign-in works only when turned on, and only from this machine" do
    {conn, _} = req(%{}, :get, "/auth/dev")
    assert conn.status == 404

    put_sign_in(:dev, true)
    {conn, _} = req(%{}, :get, "/auth/dev?next=/me")
    assert conn.status == 200
    assert conn.resp_body =~ ~s(name="email")

    {conn, _} = req(%{}, :get, "/auth/dev", remote_ip: {10, 0, 0, 5})
    assert conn.status == 404

    form = %{"email" => "Grace@Example.com", "name" => "Grace Hopper", "next" => "/me"}
    origin = [{"origin", "http://localhost:4000"}]

    # A post from another site (login CSRF) or another name for this
    # machine (DNS rebinding) is refused.
    {conn, _} = req(%{}, :post, "/auth/dev", form: form)
    assert conn.status == 403

    {conn, _} =
      req(%{}, :post, "/auth/dev", form: form, headers: [{"origin", "http://evil.example"}])

    assert conn.status == 403
    {conn, _} = req(%{}, :get, "/auth/dev", host: "rebound.evil.example")
    assert conn.status == 404

    {conn, jar} = req(%{}, :post, "/auth/dev", form: form, headers: origin)
    assert {303, "/me"} = {conn.status, location(conn)}

    {conn, _} = req(jar, :get, "/me")

    assert %{"email" => "grace@example.com", "first_name" => "Grace", "provider" => "dev"} =
             json(conn)["user"]

    {conn, _} =
      req(%{}, :post, "/auth/dev",
        form: Map.put(form, "email", "eve@blocked.example"),
        headers: origin
      )

    assert conn.status == 403

    # The domain is the email address's.
    {_conn, jar} =
      req(%{}, :post, "/auth/dev",
        form: Map.put(form, "email", "grace@gmail.com"),
        headers: origin
      )

    {conn, _} = req(jar, :get, "/me")
    assert %{"domain" => "gmail.com", "timed" => true} = json(conn)["user"]

    # Without the service set up, the setup page offers dev sign-in.
    Application.put_env(:theseus, :clients, %{})
    {conn, _} = req(%{}, :get, "/auth/acme?next=/me")
    assert conn.status == 503
    assert conn.resp_body =~ ~s(href="/auth/dev?next=%2Fme")
  end

  test "units may escape HTML with Plug.HTML" do
    {:ok, v} =
      Theseus.Version.build(
        Demo.Page,
        "defmodule Demo.Page do\ndef render(name), do: \"<b>\" <> Plug.HTML.html_escape(name) <> \"</b>\"\nend"
      )

    assert :ok = Theseus.Validator.Static.check(v, :pure)
  end
end
