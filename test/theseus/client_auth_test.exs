defmodule Theseus.ClientAuthTest do
  @moduledoc "The app's OAuth server for API clients, and bearer tokens on app requests."

  use ExUnit.Case, async: false

  import Plug.Conn
  import Theseus.TestHelpers

  alias Theseus.Clients

  @routes_extra """
    def handle(%{method: "GET", path: ["me"], user: nil}), do: {401, %{error: "sign in"}}

    def handle(%{method: "GET", path: ["me"], user: user} = request),
      do: {200, %{user: user, client: request[:client], csrf: request.csrf_token}}

    def handle(%{method: "POST", path: ["me"], body: body}), do: {200, %{saved: body["text"]}}

    def handle(_request), do: {404, %{error: "not found"}}

    def sign_in(identity), do: {:ok, %{email: identity.email}}
  """

  @redirect "https://client.example/callback"

  setup_all do
    before = snapshot()

    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}\n",
        @routes_extra
      )

    approve_settled(unit: "Sample.Routes", intent: "routes for client tests", unit_source: routes)
    on_exit(fn -> restore(before) end)
    :ok
  end

  setup do
    config = Application.get_env(:theseus, :sign_in, [])
    Application.put_env(:theseus, :sign_in, Keyword.put(config, :dev, true))
    # Each test starts with no grants, whatever another test left.
    for g <- Clients.grants(), do: Clients.revoke_grant(g.id)
    on_exit(fn -> Application.put_env(:theseus, :sign_in, config) end)
    :ok
  end

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
    conn = %{conn | host: "localhost"}
    conn = Theseus.Web.call(conn, Theseus.Web.init([]))

    jar =
      Enum.reduce(conn.resp_cookies, jar, fn
        {name, %{max_age: 0}}, jar -> Map.delete(jar, name)
        {name, %{value: value}}, jar -> Map.put(jar, name, value)
      end)

    {conn, jar}
  end

  defp json(conn), do: JSON.decode!(conn.resp_body)
  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  defp signed_in(email) do
    {conn, jar} =
      req(%{}, :post, "/auth/dev",
        form: %{"email" => email, "name" => "Someone"},
        headers: [{"origin", "http://localhost:4000"}]
      )

    assert conn.status == 303
    jar
  end

  defp csrf(jar) do
    conn =
      Enum.reduce(jar, Plug.Test.conn(:get, "/"), fn {k, v}, c ->
        Plug.Test.put_req_cookie(c, k, v)
      end)

    get_session(Theseus.SignIn.fetch(conn), "csrf")
  end

  defp register do
    {conn, _} =
      req(%{}, :post, "/oauth/register",
        json: %{"client_name" => "Test Assistant", "redirect_uris" => [@redirect]}
      )

    assert conn.status == 201
    json(conn)["client_id"]
  end

  defp verifier, do: "verifier-" <> String.duplicate("x", 40)
  defp challenge(v), do: Base.url_encode64(:crypto.hash(:sha256, v), padding: false)

  defp authorize_query(client_id, extra \\ %{}) do
    URI.encode_query(
      Map.merge(
        %{
          "response_type" => "code",
          "client_id" => client_id,
          "redirect_uri" => @redirect,
          "code_challenge" => challenge(verifier()),
          "code_challenge_method" => "S256",
          "state" => "st-1"
        },
        extra
      )
    )
  end

  # Signs in, allows the client, and returns the code.
  defp code(client_id, email \\ "ada@example.com") do
    jar = signed_in(email)
    {conn, jar} = req(jar, :get, "/oauth/authorize?" <> authorize_query(client_id))
    assert conn.status == 200 and conn.resp_body =~ "Let Test Assistant act as you?"

    {conn, _} =
      req(jar, :post, "/oauth/authorize", form: %{"decision" => "allow", "_csrf" => csrf(jar)})

    assert conn.status == 302
    q = URI.decode_query(URI.parse(location(conn)).query)
    assert String.starts_with?(location(conn), @redirect <> "?")
    assert q["state"] == "st-1" and q["iss"] == "http://localhost:4000"
    q["code"]
  end

  defp tokens(client_id) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code(client_id),
      "client_id" => client_id,
      "redirect_uri" => @redirect,
      "code_verifier" => verifier()
    }

    {conn, _} = req(%{}, :post, "/oauth/token", form: form)
    assert conn.status == 200
    json(conn)
  end

  test "metadata says where and how to get a token, and the app's 401 points there" do
    {conn, _} = req(%{}, :get, "/.well-known/oauth-protected-resource/mcp")

    assert %{
             "resource" => "http://localhost:4000/mcp",
             "authorization_servers" => ["http://localhost:4000"]
           } = json(conn)

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

    {conn, _} = req(%{}, :get, "/.well-known/oauth-authorization-server")

    assert %{
             "issuer" => "http://localhost:4000",
             "authorization_endpoint" => "http://localhost:4000/oauth/authorize",
             "token_endpoint" => "http://localhost:4000/oauth/token",
             "registration_endpoint" => "http://localhost:4000/oauth/register",
             "code_challenge_methods_supported" => ["S256"]
           } = json(conn)

    {conn, _} = req(%{}, :get, "/me")
    assert conn.status == 401

    assert get_resp_header(conn, "www-authenticate") == [
             ~s(Bearer resource_metadata="http://localhost:4000/.well-known/oauth-protected-resource/me")
           ]
  end

  test "registration takes safe redirect addresses only" do
    for uris <- [
          [],
          ["http://evil.example/cb"],
          ["javascript:alert(1)"],
          "https://x.example/cb",
          ["https://x.example/cb#frag"]
        ] do
      {conn, _} = req(%{}, :post, "/oauth/register", json: %{"redirect_uris" => uris})
      assert conn.status == 400, inspect(uris)
      assert json(conn)["error"] == "invalid_redirect_uri"
    end

    {conn, _} =
      req(%{}, :post, "/oauth/register",
        json: %{
          "redirect_uris" => ["http://127.0.0.1:3000/cb", "com.example.app:/cb"],
          "client_name" => "<b>X</b>\n"
        }
      )

    assert %{
             "client_id" => "tcl_" <> _,
             "token_endpoint_auth_method" => "none",
             "client_name" => "<b>X</b>"
           } = json(conn)
  end

  test "a person signs in, allows the client, and its token acts as them" do
    client_id = register()

    {conn, _} = req(%{}, :get, "/oauth/authorize?" <> authorize_query(client_id))
    assert conn.status == 200 and conn.resp_body =~ "Sign in to continue"
    assert conn.resp_body =~ "/auth/dev?next=%2Foauth%2Fauthorize%3F"

    tokens = tokens(client_id)

    assert %{
             "token_type" => "Bearer",
             "expires_in" => 3600,
             "access_token" => "tat_" <> _,
             "refresh_token" => "trt_" <> _
           } = tokens

    bearer = [{"authorization", "Bearer " <> tokens["access_token"]}]
    {conn, _} = req(%{}, :get, "/me", headers: bearer)

    assert %{
             "user" => %{"email" => "ada@example.com"},
             "client" => %{"name" => "Test Assistant"},
             "csrf" => nil
           } =
             json(conn)

    # A token needs no CSRF token, and a wrong token is refused before the app.
    {conn, _} = req(%{}, :post, "/me", json: %{"text" => "hi"}, headers: bearer)
    assert json(conn) == %{"saved" => "hi"}

    {conn, _} = req(%{}, :get, "/me", headers: [{"authorization", "Bearer tat_nope"}])
    assert conn.status == 401
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")

    assert [%{client: "Test Assistant", user: "ada@example.com"}] = Clients.grants()
    [grant] = Clients.grants()
    :ok = Clients.revoke_grant(grant.id)
  end

  test "a code works once, for its client, address and verifier" do
    client_id = register()

    base = %{
      "grant_type" => "authorization_code",
      "client_id" => client_id,
      "redirect_uri" => @redirect,
      "code_verifier" => verifier()
    }

    for {bad, why} <- [
          {%{"code_verifier" => "wrong"}, "verifier"},
          {%{"redirect_uri" => "https://client.example/other"}, "another client or address"},
          {%{"client_id" => "tcl_other"}, "another client or address"}
        ] do
      c = code(client_id)

      {conn, _} =
        req(%{}, :post, "/oauth/token",
          form: Map.merge(base, Map.put(bad, "code", c) |> Map.merge(%{"code" => c}))
        )

      assert %{"error" => "invalid_grant", "error_description" => d} = json(conn)
      assert d =~ why
    end

    c = code(client_id)
    {conn, _} = req(%{}, :post, "/oauth/token", form: Map.put(base, "code", c))
    assert conn.status == 200
    {conn, _} = req(%{}, :post, "/oauth/token", form: Map.put(base, "code", c))
    assert json(conn)["error"] == "invalid_grant"
  end

  test "the authorization request is checked before anyone is asked" do
    client_id = register()
    jar = signed_in("ada@example.com")

    {conn, _} = req(jar, :get, "/oauth/authorize?" <> authorize_query("tcl_unknown"))
    assert conn.status == 400

    {conn, _} =
      req(
        jar,
        :get,
        "/oauth/authorize?" <>
          authorize_query(client_id, %{"redirect_uri" => "https://evil.example/cb"})
      )

    assert conn.status == 400 and location(conn) == nil

    {conn, _} =
      req(
        jar,
        :get,
        "/oauth/authorize?" <> authorize_query(client_id, %{"code_challenge_method" => "plain"})
      )

    assert URI.decode_query(URI.parse(location(conn)).query)["error"] == "invalid_request"

    {conn, _} =
      req(
        jar,
        :get,
        "/oauth/authorize?" <>
          authorize_query(client_id, %{"resource" => "https://other.example/mcp"})
      )

    assert URI.decode_query(URI.parse(location(conn)).query)["error"] == "invalid_target"

    {conn, jar} = req(jar, :get, "/oauth/authorize?" <> authorize_query(client_id))
    assert conn.status == 200
    {conn, _} = req(jar, :post, "/oauth/authorize", form: %{"decision" => "allow"})
    assert conn.status == 403

    {_conn, jar} = req(jar, :get, "/oauth/authorize?" <> authorize_query(client_id))

    {conn, _} =
      req(jar, :post, "/oauth/authorize", form: %{"decision" => "deny", "_csrf" => csrf(jar)})

    assert %{"error" => "access_denied", "state" => "st-1"} =
             URI.decode_query(URI.parse(location(conn)).query)
  end

  test "a refresh token gives new tokens once; used again, it ends the grant; revoking ends it too" do
    client_id = register()
    t1 = tokens(client_id)

    refresh = fn token ->
      req(%{}, :post, "/oauth/token",
        form: %{
          "grant_type" => "refresh_token",
          "refresh_token" => token,
          "client_id" => client_id
        }
      )
    end

    {conn, _} = refresh.(t1["refresh_token"])
    t2 = json(conn)
    assert t2["access_token"] != t1["access_token"] and t2["refresh_token"] != t1["refresh_token"]

    {conn, _} =
      req(%{}, :get, "/me", headers: [{"authorization", "Bearer " <> t1["access_token"]}])

    assert conn.status == 401

    {conn, _} =
      req(%{}, :get, "/me", headers: [{"authorization", "Bearer " <> t2["access_token"]}])

    assert conn.status == 200

    {conn, _} = refresh.(t1["refresh_token"])
    assert json(conn)["error"] == "invalid_grant"

    {conn, _} =
      req(%{}, :get, "/me", headers: [{"authorization", "Bearer " <> t2["access_token"]}])

    assert conn.status == 401

    t3 = tokens(client_id)
    {conn, _} = req(%{}, :post, "/oauth/revoke", form: %{"token" => t3["refresh_token"]})
    assert conn.status == 200

    {conn, _} =
      req(%{}, :get, "/me", headers: [{"authorization", "Bearer " <> t3["access_token"]}])

    assert conn.status == 401
  end

  test "clients and grants survive a restart, and the file holds no tokens" do
    dir = Path.expand("../../tmp/test_clients_#{System.unique_integer([:positive])}", __DIR__)
    path = Path.join(dir, "app.theseus.clients")
    Application.put_env(:theseus, :clients_file, true)
    Application.put_env(:theseus, :clients_path, path)

    restart = fn ->
      :ok = Supervisor.terminate_child(Theseus.Supervisor, Clients)
      {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, Clients)
    end

    on_exit(fn ->
      Application.put_env(:theseus, :clients_file, false)
      Application.delete_env(:theseus, :clients_path)
      restart.()
    end)

    restart.()
    client_id = register()
    t = tokens(client_id)
    restart.()

    {conn, _} =
      req(%{}, :get, "/me", headers: [{"authorization", "Bearer " <> t["access_token"]}])

    assert conn.status == 200
    refute File.read!(path) =~ t["access_token"]
    refute File.read!(path) =~ t["refresh_token"]
  end
end
