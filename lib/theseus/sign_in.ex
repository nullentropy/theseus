defmodule Theseus.SignIn do
  @moduledoc """
  Sign-in for the application. The engine runs the sign-in protocol and
  keeps the session; the application decides who may sign in and what the
  rest of the app knows about them. Client secrets, tokens and the session
  key stay in the engine.

  People sign in with the services the app declares with `sign_in`, and
  admins connect the ones it declares with `connect` (`Theseus.Services`,
  `Theseus.OAuth`). The engine takes these requests before the endpoint
  unit sees them, for a service NAME:

      GET  /auth/NAME               sends the person to the service (`?next=/path` returns there)
      GET  /auth/NAME/callback      the service sends them back here (or NAME_REDIRECT_URL's path)
      GET  /auth/NAME/connect       connects the service for the person's domain (see Theseus.Connections)
      POST /auth/NAME/disconnect    disconnects a domain (form fields `domain`, `next`)
      POST /auth/logout             signs out (`next` returns there, default /)
      GET  /auth/dev, POST /auth/dev
                                    dev sign-in, only when enabled and only from this machine

  After the service confirms who the person is, the engine calls the
  endpoint unit's optional `sign_in/1` with their identity (`%{provider,
  id, email, name, first_name, last_name, picture, domain, now}`; `provider`
  is the service's name; `domain` comes from the service's `domain_claim`,
  or the email address; `now` is the time). It returns `{:ok, user}` to let
  them in, or `{:error, response}` to refuse with that response. Without
  `sign_in/1` the identity is the user. The user is kept in an encrypted
  cookie and passed to every request as `request.user`; keep it small.

  Connecting and disconnecting need a signed-in user, and the endpoint
  unit's `allow?/1` must return true for `%{action: "connect" |
  "disconnect", service: name, domain: domain_or_nil, user: user, now:
  now}`. Without `allow?/1`, nobody may. Connecting asks twice: before
  sending the person to the service, with no domain, and after, with the
  domain the service named.

  Signed-in requests that change something (anything but GET, HEAD and
  OPTIONS) must carry the session's CSRF token, `request.csrf_token`, as a
  `_csrf` form or JSON field or an `x-csrf-token` header; the engine refuses
  them with 403 otherwise. Sessions end after config `session_hours`.

  Config (`config :theseus, :sign_in`):

    * `session_hours`: how long a sign-in lasts (default 12).
    * `idle_minutes`: a session with no request for this long ends
      (`THESEUS_IDLE_MINUTES`; off by default).
    * `dev`: dev sign-in (`THESEUS_DEV_SIGN_IN=1`). A form asks for an email
      and a name and signs in as that person with provider "dev", through
      the app's `sign_in/1` like any other sign-in; the domain is the
      email address's. Only requests from 127.0.0.1 or ::1, with a local
      Host (or the public URL's), can use it, and its form must post from
      the same site. Production builds ignore the setting: behind a reverse
      proxy every request comes from 127.0.0.1.
  """

  import Plug.Conn

  alias Theseus.{OAuth, Services}

  @cookie "_theseus_session"
  @flow_ttl_s 600
  @max_user_bytes 2_048

  # Sessions ---------------------------------------------------------------

  @doc "Sets up the session for a request and drops it when it has expired."
  @spec fetch(Plug.Conn.t()) :: Plug.Conn.t()
  def fetch(conn) do
    conn = %{conn | secret_key_base: secret_key_base()}
    conn = conn |> Plug.Session.call(session_opts()) |> fetch_session()

    now = System.os_time(:second)
    idle = idle_seconds()
    at = get_session(conn, "at")
    seen = get_session(conn, "seen") || at

    cond do
      not is_integer(at) ->
        conn

      now - at > session_hours() * 3600 ->
        clear_session(conn)

      idle != nil and now - seen > idle ->
        clear_session(conn)

      # Activity is noted at most once a minute, so the cookie is not
      # rewritten on every request.
      idle != nil and now - seen >= 60 ->
        put_session(conn, "seen", now)

      true ->
        conn
    end
  end

  defp idle_seconds do
    case Keyword.get(Application.get_env(:theseus, :sign_in, []), :idle_minutes) do
      minutes when is_integer(minutes) and minutes > 0 -> minutes * 60
      _ -> nil
    end
  end

  @doc "The signed-in user, or nil."
  @spec user(Plug.Conn.t()) :: term()
  def user(conn), do: get_session(conn, "user")

  @doc "The session's CSRF token, or nil when nobody is signed in."
  @spec csrf_token(Plug.Conn.t()) :: String.t() | nil
  def csrf_token(conn), do: get_session(conn, "csrf")

  @doc "Whether a request that changes something carries the session's CSRF token."
  @spec csrf_ok?(Plug.Conn.t()) :: boolean()
  def csrf_ok?(%{method: method}) when method in ~w(GET HEAD OPTIONS), do: true

  def csrf_ok?(conn) do
    case csrf_token(conn) do
      nil ->
        true

      expected ->
        given =
          case conn.body_params do
            %{"_csrf" => token} when is_binary(token) -> token
            _ -> List.first(get_req_header(conn, "x-csrf-token")) || ""
          end

        Plug.Crypto.secure_compare(given, expected)
    end
  end

  defp session_hours,
    do: Keyword.get(Application.get_env(:theseus, :sign_in, []), :session_hours, 12)

  defp session_opts do
    Plug.Session.init(
      store: :cookie,
      key: @cookie,
      signing_salt: "theseus sign-in",
      encryption_salt: "theseus session",
      same_site: "Lax",
      http_only: true,
      secure: String.starts_with?(Theseus.Web.public_url(), "https://"),
      max_age: session_hours() * 3600
    )
  end

  defp secret_key_base do
    case :persistent_term.get({__MODULE__, :secret}, nil) do
      nil ->
        secret = Base.encode16(Theseus.Keys.session(), case: :lower)
        :persistent_term.put({__MODULE__, :secret}, secret)
        secret

      secret ->
        secret
    end
  end

  # Routes ----------------------------------------------------------------

  @doc """
  Handles the engine's sign-in requests. Returns the sent conn, or `:pass`
  when the request is for the app.
  """
  @spec route(Plug.Conn.t()) :: Plug.Conn.t() | :pass
  def route(%{method: "POST", path_info: ["auth", "logout"]} = conn), do: logout(conn)

  def route(%{path_info: ["auth", "dev"]} = conn) do
    cond do
      not dev?() or not local?(conn) or not local_host?(conn) ->
        :pass

      conn.method == "POST" and not same_origin?(conn) ->
        page(conn, 403, "Dev sign-in", "The form must come from this site.")

      conn.method == "GET" ->
        dev_form(conn)

      conn.method == "POST" ->
        dev_sign_in(conn)

      true ->
        :pass
    end
  end

  # The service sends people back to the public URL's host. A flow started
  # on another name for this machine would lose its session cookie on the
  # way, so it starts again on the right host first.
  def route(%{method: "GET", path_info: ["auth", name | rest]} = conn)
      when rest in [[], ["connect"]] do
    flow = if rest == [], do: :sign_in, else: :connect

    case Services.get(name) do
      %{^flow => %{}} = service ->
        case other_local_host(conn) do
          nil when flow == :sign_in -> sign_in_start(conn, service)
          nil -> connect_start(conn, service)
          url -> Theseus.Web.respond_external(conn, url)
        end

      _ ->
        callback_or_pass(conn)
    end
  end

  def route(%{method: "POST", path_info: ["auth", name, "disconnect"]} = conn) do
    case Services.get(name) do
      %{connect: %{}} = service -> disconnect(conn, service)
      _ -> :pass
    end
  end

  def route(%{method: "GET"} = conn), do: callback_or_pass(conn)

  def route(_conn), do: :pass

  defp callback_or_pass(conn) do
    case OAuth.callback_service(conn.path_info) do
      nil -> :pass
      service -> callback(conn, service)
    end
  end

  defp sign_in_start(conn, service) do
    if OAuth.client(service.name) do
      to_service(conn, service, :sign_in, query_param(conn, "login_hint"))
    else
      dev =
        if dev?() and local?(conn) do
          next = local_path(query_param(conn, "next"))
          query = if next, do: "?" <> URI.encode_query(%{"next" => next}), else: ""

          ~s(<p><a href="/auth/dev#{Plug.HTML.html_escape(query)}">Use dev sign-in instead</a></p>)
        else
          ""
        end

      send_page(conn, 503, "Sign-in with #{service.name} is not set up", not_set_up(service), dev)
    end
  end

  defp not_set_up(service) do
    name = String.upcase(service.name)

    "Set #{name}_CLIENT_ID and #{name}_CLIENT_SECRET and restart Theseus. " <>
      "The OAuth client's redirect URL must be " <>
      (Theseus.Web.public_url() <> "/auth/#{service.name}/callback") <>
      ", or set #{name}_REDIRECT_URL."
  end

  # Sends the person to the service with a new flow kept in the session.
  defp to_service(conn, service, purpose, login_hint) do
    state = token()
    nonce = token()
    verifier = token(48)

    flow = %{
      "service" => service.name,
      "purpose" => Atom.to_string(purpose),
      "state" => state,
      "nonce" => nonce,
      "verifier" => verifier,
      "next" => local_path(query_param(conn, "next")),
      "at" => System.os_time(:second)
    }

    url =
      OAuth.authorize_url(service, purpose,
        state: state,
        nonce: nonce,
        challenge: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        login_hint: login_hint
      )

    conn
    |> put_session("flow", flow)
    |> put_resp_header("cache-control", "no-store")
    |> Theseus.Web.respond_external(url)
  end

  defp other_local_host(conn) do
    public = URI.parse(Theseus.Web.public_url())
    local = ["localhost", "127.0.0.1", "::1", "[::1]"]

    if conn.host in local and public.host in local and conn.host != public.host do
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
      Theseus.Web.public_url() <> conn.request_path <> query
    end
  end

  # Connecting a service (see Theseus.Connections). The person must be
  # signed in, and the app's allow?/1 must agree.
  defp connect_start(conn, service) do
    user = user(conn)

    cond do
      user == nil ->
        page(conn, 401, "Sign in first", "Sign in, then connect #{service.name}.")

      OAuth.client(service.name) == nil ->
        page(conn, 503, "#{service.name} is not set up", not_set_up(service))

      not allowed?(conn, "connect", service, nil) ->
        page(conn, 403, "Not allowed", "This app does not let you connect #{service.name}.")

      true ->
        hint = if is_map(user), do: user[:email] || user["email"]
        to_service(conn, service, :connect, hint)
    end
  end

  defp disconnect(conn, service) do
    user = user(conn)
    domain = body_param(conn, "domain")
    next = local_path(body_param(conn, "next")) || "/"

    cond do
      user == nil ->
        page(conn, 401, "Sign in first", "Sign in to manage connections.")

      not csrf_ok?(conn) ->
        Theseus.Web.respond(conn, {403, %{error: "missing or wrong CSRF token"}})

      not is_binary(domain) ->
        page(conn, 422, "Which domain?", "Say which domain to disconnect.")

      not allowed?(conn, "disconnect", service, domain) ->
        page(conn, 403, "Not allowed", "This app does not let you disconnect #{domain}.")

      true ->
        by = if is_map(user), do: user[:email] || user["email"]

        case Theseus.Connections.disconnect(service.name, domain, by) do
          :ok ->
            Theseus.Web.respond(conn, {:redirect, next})

          {:error, :not_connected} ->
            page(conn, 404, "Not connected", "#{domain} is not connected to #{service.name}.")
        end
    end
  end

  # The app decides who may manage connections, through its endpoint unit's
  # allow?/1. Without one, nobody may.
  defp allowed?(conn, action, service, domain) do
    with unit when unit != nil <- Theseus.Web.endpoint(),
         true <- function_exported?(unit, :allow?, 1) do
      request = %{
        action: action,
        service: service.name,
        domain: domain,
        user: user(conn),
        now: DateTime.utc_now()
      }

      Theseus.Store.run("#{inspect(unit)}.allow?", fn ->
        Theseus.call(unit, :allow?, [request])
      end) ==
        true
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp callback(conn, service) do
    flow = get_session(conn, "flow")
    params = Map.new(["error", "state", "code"], &{&1, query_param(conn, &1)})
    conn = delete_session(conn, "flow")

    cond do
      is_binary(params["error"]) ->
        page(conn, 401, "You are not signed in", "#{service.name} said: #{params["error"]}.")

      not is_map(flow) or flow["service"] != service.name or
          System.os_time(:second) - flow["at"] > @flow_ttl_s ->
        page(
          conn,
          400,
          "This sign-in has expired",
          "It took too long, or it was started in another browser. Try again."
        )

      not Plug.Crypto.secure_compare(params["state"] || "", flow["state"]) ->
        page(conn, 400, "This sign-in does not match", "Start again from the sign-in page.")

      flow["purpose"] == "connect" ->
        connect_callback(conn, service, params, flow)

      true ->
        with {:ok, claims, _tokens} <-
               OAuth.exchange(service, params["code"] || "", flow["verifier"]),
             {:ok, identity} <- OAuth.identity(service, claims, flow["nonce"], DateTime.utc_now()) do
          complete(conn, identity, flow["next"])
        else
          {:error, reason} -> page(conn, 401, "You are not signed in", sentence(reason))
        end
    end
  end

  defp connect_callback(conn, service, params, flow) do
    result =
      with {:ok, claims, tokens} <-
             OAuth.exchange(service, params["code"] || "", flow["verifier"]),
           {:ok, identity} <- OAuth.identity(service, claims, flow["nonce"], DateTime.utc_now()) do
        granted = tokens.scopes || service.connect.scopes
        missing = service.connect.required_scopes -- granted

        cond do
          tokens.refresh_token == nil and tokens.expires_at != nil ->
            {:error,
             "#{service.name} gave no refresh token, so Theseus could not keep the connection"}

          missing != [] ->
            {:error, "access was not granted to #{Enum.join(missing, ", ")}"}

          identity.domain == nil ->
            {:error, "connect with an account of an organization, not a personal one"}

          true ->
            {:ok, identity, %{tokens | scopes: granted}}
        end
      end

    case result do
      # The service says which domain the account belongs to only now, so
      # the app is asked again, about that domain, by the person still
      # signed in.
      {:ok, identity, tokens} ->
        cond do
          user(conn) == nil ->
            OAuth.revoke(service, tokens.refresh_token || tokens.access_token)
            page(conn, 401, "Sign in first", "Sign in, then connect #{service.name}.")

          not allowed?(conn, "connect", service, identity.domain) ->
            OAuth.revoke(service, tokens.refresh_token || tokens.access_token)

            page(
              conn,
              403,
              "Not allowed",
              "This app does not let you connect #{service.name} for #{identity.domain}."
            )

          true ->
            :ok = Theseus.Connections.connect(service.name, identity, tokens)
            Theseus.Web.respond(conn, {:redirect, flow["next"] || "/"})
        end

      {:error, reason} ->
        page(conn, 401, "#{service.name} is not connected", sentence(reason))
    end
  end

  defp dev_form(conn) do
    next = local_path(query_param(conn, "next"))

    form = """
    <form method="post" action="/auth/dev">
      <label>Email <input name="email" type="email" required autofocus></label>
      <label>Name <input name="name" required></label>
      <input type="hidden" name="next" value="#{Plug.HTML.html_escape(next || "")}">
      <button>Sign in</button>
    </form>
    """

    send_page(conn, 200, "Dev sign-in", "Signs in as anyone, from this machine only.", form)
  end

  defp dev_sign_in(conn) do
    email = conn |> body_param("email") |> to_string() |> String.trim() |> String.downcase()
    name = conn |> body_param("name") |> to_string() |> String.trim()

    case String.split(email, "@") do
      [local, domain] when local != "" and domain != "" and name != "" ->
        {first, last} =
          case String.split(name, " ", parts: 2) do
            [first, last] -> {first, last}
            [first] -> {first, nil}
          end

        identity = %{
          provider: "dev",
          id: "dev:" <> email,
          email: email,
          name: name,
          first_name: first,
          last_name: last,
          picture: nil,
          domain: domain
        }

        complete(conn, identity, local_path(body_param(conn, "next")))

      _ ->
        page(conn, 422, "Dev sign-in", "Give an email address and a name.")
    end
  end

  defp logout(conn) do
    if csrf_ok?(conn) do
      next = local_path(body_param(conn, "next") || query_param(conn, "next")) || "/"

      conn
      |> configure_session(drop: true)
      |> Theseus.Web.respond({:redirect, next})
    else
      Theseus.Web.respond(conn, {403, %{error: "missing or wrong CSRF token"}})
    end
  end

  # Asks the app whether this person may sign in, then starts the session.
  defp complete(conn, identity, next) do
    case app_sign_in(identity) do
      {:ok, user} ->
        if byte_size(:erlang.term_to_binary(user)) > @max_user_bytes do
          page(
            conn,
            500,
            "Sign-in failed",
            "The app's sign_in/1 returned a user too large for a cookie. Keep it to an id and a few fields."
          )
        else
          conn
          |> configure_session(renew: true)
          |> put_session("user", user)
          |> put_session("at", System.os_time(:second))
          |> put_session("csrf", csrf_token_value())
          |> Theseus.Web.respond({:redirect, next || "/"})
        end

      {:error, response} ->
        Theseus.Web.respond(conn, response)

      :crashed ->
        page(conn, 500, "Sign-in failed", "The app could not finish signing you in.")

      _other ->
        page(
          conn,
          500,
          "Sign-in failed",
          "The app's sign_in/1 returned neither {:ok, user} nor {:error, response}."
        )
    end
  end

  defp app_sign_in(identity) do
    case Theseus.Web.endpoint() do
      nil ->
        {:ok, identity}

      unit ->
        if function_exported?(unit, :sign_in, 1) do
          identity = Map.put(identity, :now, DateTime.utc_now())

          Theseus.Effects.run("#{inspect(unit)}.sign_in", fn ->
            Theseus.call(unit, :sign_in, [identity])
          end)
        else
          {:ok, identity}
        end
    end
  rescue
    _ -> :crashed
  catch
    _, _ -> :crashed
  end

  # Helpers ---------------------------------------------------------------

  # Form and query values, only when they are strings: a list or map from
  # `x[]=` or `x[k]=`, or a body that was not parsed, counts as missing.
  defp body_param(%{body_params: %{} = params} = _conn, key) when not is_struct(params),
    do: string_or_nil(params[key])

  defp body_param(_conn, _key), do: nil

  defp query_param(%{query_params: params}, key), do: string_or_nil(params[key])

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp dev?, do: Keyword.get(Application.get_env(:theseus, :sign_in, []), :dev, false) == true

  @doc false
  # Whether this request may use dev sign-in.
  def dev_for?(conn), do: dev?() and local?(conn) and local_host?(conn)

  defp local?(%{remote_ip: {127, _, _, _}}), do: true
  defp local?(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp local?(_conn), do: false

  # A page on another site can point its own name at 127.0.0.1; the Host
  # header still carries that name.
  defp local_host?(conn),
    do: conn.host in ["localhost", "127.0.0.1", "::1", URI.parse(Theseus.Web.public_url()).host]

  # Browsers send Origin with form posts; one from another site is refused.
  defp same_origin?(conn) do
    case get_req_header(conn, "origin") do
      [origin] -> URI.parse(origin).host == conn.host
      _ -> false
    end
  end

  @doc false
  # Only paths on this site, so a sign-in link cannot send people elsewhere.
  # Browsers drop tabs and other control characters from a URL before
  # reading it, so "/\t/evil.example" would leave the site.
  def local_path("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]) or String.contains?(path, "\\") or
         String.match?(path, ~r/[\x00-\x1f\x7f]/),
       do: nil,
       else: path
  end

  def local_path(_), do: nil

  defp sentence(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest <> "."

  # The prefix lets redaction find the token wherever a unit passes it.
  defp csrf_token_value, do: "tcsrf_" <> token()

  defp token(bytes \\ 24), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp page(conn, status, title, message), do: send_page(conn, status, title, message, "")

  @doc false
  # An engine page in the sign-in style; `extra` is trusted HTML.
  def send_page(conn, status, title, message, extra) do
    html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{Plug.HTML.html_escape(title)}</title>
    <style>
      body { font: 16px/1.5 system-ui, sans-serif; color: #1d2433; background: #f6f7f9; margin: 0; }
      main { max-width: 26rem; margin: 12vh auto; padding: 2rem; background: #fff; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
      h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
      p { margin: 0 0 1rem; color: #4a5263; }
      label { display: block; margin: 0 0 .75rem; font-size: .9rem; }
      input { display: block; width: 100%; box-sizing: border-box; padding: .5rem; margin-top: .25rem; border: 1px solid #cdd2db; border-radius: 6px; font: inherit; }
      button { padding: .5rem 1rem; border: 0; border-radius: 6px; background: #2754d6; color: #fff; font: inherit; cursor: pointer; }
      a { color: #2754d6; }
    </style>
    </head>
    <body><main>
    <h1>#{Plug.HTML.html_escape(title)}</h1>
    <p>#{Plug.HTML.html_escape(message)}</p>
    #{extra}
    <p><a href="/">Home</a></p>
    </main></body>
    </html>
    """

    Theseus.Web.respond(conn, {status, :html, html})
  end
end
