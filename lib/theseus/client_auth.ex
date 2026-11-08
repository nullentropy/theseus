defmodule Theseus.ClientAuth do
  @moduledoc """
  The OAuth 2.1 authorization server for the app's API clients, such as an
  AI assistant using the app's MCP server (see `Theseus.Clients`). The
  engine takes these requests before the endpoint unit sees them:

      GET  /.well-known/oauth-protected-resource[/PATH]  where to get a token (RFC 9728)
      GET  /.well-known/oauth-authorization-server        how to get one (RFC 8414)
      POST /oauth/register                                a client registers itself (RFC 7591)
      GET  /oauth/authorize, POST /oauth/authorize        a person signs in and lets the client act as them
      POST /oauth/token                                   a code or refresh token for tokens
      POST /oauth/revoke                                  gives up a token (RFC 7009)

  Clients are public and must use PKCE with S256. The person signs in with
  the app's sign-in services, as on the app's own pages, and sees a page
  that names the client before it gets a code.

  A request to the app with `Authorization: Bearer TOKEN` reaches the
  endpoint unit with `user` set to the person's user, `csrf_token` nil, and
  `client: %{id, name}` saying which client acts; a token that is not valid
  is refused with 401 before the app sees it. Every 401 the app sends
  carries `WWW-Authenticate` pointing at the metadata, so a client knows
  where to get a token. What a client may do is the app's decision, as for
  anyone signed in.
  """

  import Plug.Conn

  alias Theseus.{Clients, Services, SignIn, Web}

  @pending_s 600

  @doc "Handles the engine's OAuth requests for API clients. Returns the sent conn, or `:pass`."
  @spec route(Plug.Conn.t()) :: Plug.Conn.t() | :pass
  def route(%{method: "OPTIONS", path_info: path} = conn) do
    if cors?(path), do: conn |> cors() |> send_resp(204, ""), else: :pass
  end

  def route(
        %{method: "GET", path_info: [".well-known", "oauth-protected-resource" | rest]} = conn
      ) do
    base = Web.public_url()
    resource = if rest == [], do: base, else: base <> "/" <> Enum.join(rest, "/")

    json(conn, 200, %{
      resource: resource,
      authorization_servers: [base],
      bearer_methods_supported: ["header"]
    })
  end

  def route(%{method: "GET", path_info: [".well-known", "oauth-authorization-server" | _]} = conn) do
    base = Web.public_url()

    json(conn, 200, %{
      issuer: base,
      authorization_endpoint: base <> "/oauth/authorize",
      token_endpoint: base <> "/oauth/token",
      registration_endpoint: base <> "/oauth/register",
      revocation_endpoint: base <> "/oauth/revoke",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      revocation_endpoint_auth_methods_supported: ["none"]
    })
  end

  def route(%{method: "POST", path_info: ["oauth", "register"]} = conn) do
    case Clients.register(params(conn)) do
      {:ok, c} ->
        json(conn, 201, %{
          client_id: c.id,
          client_name: c.name,
          redirect_uris: c.redirect_uris,
          client_id_issued_at: DateTime.to_unix(c.created_at),
          token_endpoint_auth_method: "none",
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"]
        })

      {:error, why} ->
        kind =
          if why =~ "redirect_uris", do: "invalid_redirect_uri", else: "invalid_client_metadata"

        json(conn, 400, %{error: kind, error_description: why})
    end
  end

  def route(%{method: "GET", path_info: ["oauth", "authorize"]} = conn), do: authorize(conn)

  def route(%{method: "POST", path_info: ["oauth", "authorize"]} = conn), do: decide(conn)

  def route(%{method: "POST", path_info: ["oauth", "token"]} = conn) do
    p = params(conn)

    result =
      cond do
        not resource_ok?(p["resource"]) ->
          {:error, "invalid_target", "the resource is not this app"}

        p["grant_type"] == "authorization_code" ->
          Clients.exchange(p)

        p["grant_type"] == "refresh_token" and is_binary(p["refresh_token"]) ->
          Clients.refresh(p["refresh_token"], p["client_id"])

        true ->
          {:error, "unsupported_grant_type", "use authorization_code or refresh_token"}
      end

    case result do
      {:ok, tokens} -> conn |> put_resp_header("cache-control", "no-store") |> json(200, tokens)
      {:error, error, why} -> json(conn, 400, %{error: error, error_description: why})
    end
  end

  def route(%{method: "POST", path_info: ["oauth", "revoke"]} = conn) do
    case params(conn)["token"] do
      token when is_binary(token) -> :ok = Clients.revoke(token)
      _ -> :ok
    end

    json(conn, 200, %{})
  end

  def route(_conn), do: :pass

  @doc """
  The person behind a request's bearer token: `:none` without one,
  `{:ok, user, client}`, or `:invalid`.
  """
  @spec bearer(Plug.Conn.t()) :: :none | :invalid | {:ok, term(), map()}
  def bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        case Clients.verify(String.trim(token)) do
          {:ok, user, client} -> {:ok, user, client}
          :error -> :invalid
        end

      _ ->
        :none
    end
  end

  @doc "The `WWW-Authenticate` value for a refused request to this path."
  @spec challenge(Plug.Conn.t(), String.t() | nil) :: String.t()
  def challenge(conn, error \\ nil) do
    metadata = Web.public_url() <> "/.well-known/oauth-protected-resource" <> path(conn)
    base = ~s(Bearer resource_metadata="#{metadata}")
    if error, do: base <> ~s(, error="#{error}"), else: base
  end

  defp path(%{request_path: "/"}), do: ""
  defp path(%{request_path: path}), do: path

  # The person asked, after they sign in, whether the client may act as them.
  defp authorize(conn) do
    q = conn.query_params
    client = Clients.client(q["client_id"])

    cond do
      client == nil ->
        page(conn, 400, "Unknown client", "This app does not know the client that sent you here.")

      q["redirect_uri"] not in client.redirect_uris ->
        page(
          conn,
          400,
          "Wrong address",
          "The client asked to come back to an address it did not register."
        )

      q["response_type"] != "code" ->
        back(conn, q, error: "unsupported_response_type")

      not is_binary(q["code_challenge"]) or q["code_challenge_method"] != "S256" ->
        back(conn, q, error: "invalid_request", error_description: "PKCE with S256 is required")

      not resource_ok?(q["resource"]) ->
        back(conn, q, error: "invalid_target")

      SignIn.user(conn) == nil ->
        sign_in_first(conn, client)

      true ->
        pending = %{
          "client_id" => client.id,
          "redirect_uri" => q["redirect_uri"],
          "challenge" => q["code_challenge"],
          "state" => q["state"],
          "at" => System.os_time(:second)
        }

        conn |> put_session("oauth", pending) |> consent(client)
    end
  end

  defp decide(conn) do
    pending = get_session(conn, "oauth")
    conn = delete_session(conn, "oauth")
    user = SignIn.user(conn)

    cond do
      user == nil or not is_map(pending) or System.os_time(:second) - pending["at"] > @pending_s ->
        page(conn, 400, "This request has expired", "Go back to the client and start again.")

      not SignIn.csrf_ok?(conn) ->
        Web.respond(conn, {403, %{error: "missing or wrong CSRF token"}})

      conn.body_params["decision"] == "allow" ->
        code =
          Clients.code(%{
            client_id: pending["client_id"],
            redirect_uri: pending["redirect_uri"],
            challenge: pending["challenge"],
            user: user
          })

        back(conn, pending, code: code, iss: Web.public_url())

      true ->
        back(conn, pending, error: "access_denied")
    end
  end

  # Sends the person back to the client's registered address.
  defp back(conn, q, fields) do
    uri = q["redirect_uri"]
    state = if is_binary(q["state"]), do: [state: q["state"]], else: []
    query = URI.encode_query(fields ++ state)
    joiner = if String.contains?(uri, "?"), do: "&", else: "?"

    conn
    |> put_resp_header("cache-control", "no-store")
    |> Web.respond_external(uri <> joiner <> query)
  end

  defp sign_in_first(conn, client) do
    next = conn.request_path <> "?" <> conn.query_string

    services =
      for {name, %{sign_in: %{}}} <- Enum.sort(Services.all()) do
        ~s(<p><a href="/auth/#{name}?#{URI.encode_query(next: next)}">Sign in with #{h(name)}</a></p>)
      end

    dev =
      if SignIn.dev_for?(conn),
        do: [~s(<p><a href="/auth/dev?#{URI.encode_query(next: next)}">Use dev sign-in</a></p>)],
        else: []

    links = services ++ dev

    message =
      if links == [],
        do: "#{client.name} wants to act as you here, but this app has no way to sign in.",
        else: "#{client.name} wants to act as you here. Sign in first."

    SignIn.send_page(conn, 200, "Sign in to continue", message, Enum.join(links))
  end

  defp consent(conn, client) do
    user = SignIn.user(conn)
    who = if is_map(user), do: user[:email] || user["email"] || "you", else: "you"
    host = URI.parse(Web.public_url()).host
    csrf = h(SignIn.csrf_token(conn) || "")

    form = """
    <p>It will be able to do what you can do in the app, as #{h(who)}, until you or an admin revoke it.</p>
    <form method="post" action="/oauth/authorize">
      <input type="hidden" name="_csrf" value="#{csrf}">
      <button name="decision" value="allow">Allow</button>
      <button name="decision" value="deny" style="background:#fff;color:#2754d6;border:1px solid #cdd2db">Deny</button>
    </form>
    """

    conn
    |> put_resp_header("cache-control", "no-store")
    |> SignIn.send_page(
      200,
      "Let #{client.name} act as you?",
      "#{client.name} asks to use #{host} as you.",
      form
    )
  end

  defp resource_ok?(nil), do: true

  defp resource_ok?(r) when is_binary(r),
    do: String.starts_with?(r <> "/", Web.public_url() <> "/")

  defp resource_ok?(_), do: false

  defp params(%{body_params: %{} = p}) when not is_struct(p), do: p
  defp params(_conn), do: %{}

  defp cors?([".well-known", "oauth-protected-resource" | _]), do: true
  defp cors?([".well-known", "oauth-authorization-server" | _]), do: true
  defp cors?(["oauth", what]) when what in ["register", "token", "revoke"], do: true
  defp cors?(_), do: false

  defp cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header(
      "access-control-allow-headers",
      "authorization, content-type, mcp-protocol-version"
    )
  end

  defp json(conn, status, body) do
    conn
    |> cors()
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp page(conn, status, title, message), do: SignIn.send_page(conn, status, title, message, "")

  defp h(text), do: text |> to_string() |> Plug.HTML.html_escape()
end
