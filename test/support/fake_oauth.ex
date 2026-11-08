defmodule Theseus.FakeOAuth do
  @moduledoc false
  # A service for tests: an OAuth token endpoint, a revoke endpoint and an
  # API. The test services unit declares https addresses
  # (`services_source/0`), and `use/1` points them here.
  #
  # `expect/4` registers the claims to return for a code; the verifier must
  # match the challenge sent to the authorize URL. `answer/2` scripts the
  # API's responses for a path; `requests/0` lists what reached it.

  use Plug.Router

  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON
  plug :match
  plug :dispatch

  @secret "test-secret"

  def start do
    {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}"}
  end

  @doc """
  Points the test service's addresses at the fake running at `base`, and
  sets up its OAuth client. Returns a function that puts the config back.
  """
  def use(base) do
    before = for key <- [:http, :clients], do: {key, Application.get_env(:theseus, key)}

    Application.put_env(:theseus, :http,
      rewrite: [
        {"https://oauth.example/", base <> "/"},
        {"https://accounts.example/.well-known/", base <> "/accounts/.well-known/"},
        {"https://api.example/", base <> "/api/"}
      ]
    )

    Application.put_env(:theseus, :clients, %{
      "acme" => [client_id: "test-client", client_secret: @secret]
    })

    reset()

    fn ->
      for {key, value} <- before,
          do:
            if(value == nil,
              do: Application.delete_env(:theseus, key),
              else: Application.put_env(:theseus, key, value)
            )
    end
  end

  @doc "The test app's services unit: `acme`, which signs people in, connects, and has an API."
  def services_source do
    """
    defmodule Sample.Services do
      use Theseus.Services

      def services do
        %{
          acme: %{
            authorize_url: "https://accounts.example/o/oauth2/v2/auth",
            token_url: "https://oauth.example/token",
            revoke_url: "https://oauth.example/revoke",
            issuers: ["https://accounts.example"],
            domain_claim: "hd",
            sign_in: %{scopes: ["openid", "email", "profile"], params: %{prompt: "select_account"}},
            connect: %{
              scopes: ["openid", "email", "https://api.example/read"],
              required_scopes: ["https://api.example/read"],
              params: %{access_type: "offline", prompt: "consent"}
            },
            urls: ["https://api.example/v1/"]
          },
          open: %{urls: ["https://api.example/public/"]}
        }
      end
    end
    """
  end

  @doc "Registers the test services unit. Returns a function that removes it."
  def register_services do
    {:ok, v} = Theseus.Version.build(Sample.Services, services_source())
    {:ok, _} = Theseus.Loader.register(v, kind: :pure, actor: :system)
    fn -> Theseus.Loader.unregister(Sample.Services, actor: :system) end
  end

  @doc "Forgets scripted answers and recorded requests."
  def reset do
    :persistent_term.put({__MODULE__, :answers}, %{})
    :persistent_term.put({__MODULE__, :requests}, [])
    :persistent_term.put({__MODULE__, :revoked}, [])
  end

  @doc """
  Registers the claims (and extra token fields, such as `refresh_token`,
  `scope` and `expires_in`) to return for a code.
  """
  def expect(code, challenge, claims, tokens \\ %{}),
    do:
      :persistent_term.put({__MODULE__, code}, %{
        challenge: challenge,
        claims: claims,
        tokens: tokens
      })

  @doc "The access token a refresh token renews to."
  def refreshes(refresh_token, access_token),
    do: :persistent_term.put({__MODULE__, :refresh, refresh_token}, access_token)

  @doc "Tokens revoked so far."
  def revoked, do: :persistent_term.get({__MODULE__, :revoked}, [])

  @doc """
  The API's answers for a path under /api, such as "/v1/users": a list of
  `{status, body}` used in turn, the last one again once the others are
  used. A body that is a map is sent as JSON.
  """
  def answer(path, answers),
    do:
      :persistent_term.put(
        {__MODULE__, :answers},
        Map.put(:persistent_term.get({__MODULE__, :answers}, %{}), path, List.wrap(answers))
      )

  @doc "The requests that reached the API, oldest first."
  def requests, do: Enum.reverse(:persistent_term.get({__MODULE__, :requests}, []))

  def claims(nonce, extra \\ %{}) do
    Map.merge(
      %{
        "iss" => "https://accounts.example",
        "aud" => "test-client",
        "sub" => "1001",
        "email" => "ada@example.com",
        "email_verified" => true,
        "name" => "Ada Lovelace",
        "given_name" => "Ada",
        "family_name" => "Lovelace",
        "hd" => "example.com",
        "nonce" => nonce,
        "exp" => System.os_time(:second) + 3600
      },
      extra
    )
  end

  post "/token" do
    params = conn.body_params

    if params["grant_type"] == "refresh_token",
      do: refresh(conn, params),
      else: code(conn, params)
  end

  # Discovery, for the review site's sign-in (Theseus.ReviewSignIn).
  get "/accounts/.well-known/openid-configuration" do
    reply(conn, 200, %{
      issuer: "https://accounts.example",
      authorization_endpoint: "https://accounts.example/o/oauth2/v2/auth",
      token_endpoint: "https://oauth.example/token"
    })
  end

  post "/revoke" do
    token = conn.body_params["token"]
    :persistent_term.put({__MODULE__, :revoked}, [token | revoked()])
    send_resp(conn, 200, "")
  end

  match "/api/*path" do
    path = "/" <> Enum.join(path, "/")

    seen = %{
      method: conn.method,
      path: path,
      query: URI.decode_query(conn.query_string),
      authorization: conn |> get_req_header("authorization") |> List.first(),
      content_type: conn |> get_req_header("content-type") |> List.first(),
      body: conn.body_params
    }

    :persistent_term.put({__MODULE__, :requests}, [
      seen | :persistent_term.get({__MODULE__, :requests}, [])
    ])

    answers = :persistent_term.get({__MODULE__, :answers}, %{})

    case Map.get(answers, path, [{404, %{error: "not found"}}]) do
      [{status, body} | rest] ->
        if rest != [], do: answer(path, rest)

        case body do
          %{} -> reply(conn, status, body)
          text -> conn |> put_resp_content_type("text/plain") |> send_resp(status, text)
        end
    end
  end

  defp refresh(conn, params) do
    case :persistent_term.get({__MODULE__, :refresh, params["refresh_token"]}, nil) do
      nil ->
        reply(conn, 400, %{
          error: "invalid_grant",
          error_description: "Token has been expired or revoked."
        })

      access ->
        reply(conn, 200, %{access_token: access, expires_in: 3599, token_type: "Bearer"})
    end
  end

  defp code(conn, params) do
    expected = :persistent_term.get({__MODULE__, params["code"]}, nil)

    cond do
      expected == nil or params["client_secret"] != @secret or
          params["grant_type"] != "authorization_code" ->
        reply(conn, 400, %{error: "invalid_grant", error_description: "Bad Request"})

      challenge(params["code_verifier"] || "") != expected.challenge ->
        reply(conn, 400, %{error: "invalid_grant", error_description: "code_verifier mismatch"})

      true ->
        token =
          "e30." <> Base.url_encode64(JSON.encode!(expected.claims), padding: false) <> ".c2ln"

        reply(
          conn,
          200,
          Map.merge(
            %{id_token: token, access_token: "at-test", expires_in: 3599},
            expected.tokens
          )
        )
    end
  end

  defp challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
