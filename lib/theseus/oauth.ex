defmodule Theseus.OAuth do
  @moduledoc """
  OAuth 2.0 and OpenID Connect with the services an app declares
  (`Theseus.Services`): sign-in, connecting a service for a domain,
  renewing and revoking tokens. Authorization code flow with PKCE.

  The engine exchanges the code for an ID token at the service's token
  endpoint over verified TLS, with the client secret, so the token's
  signature is not checked again (OpenID Connect Core 3.1.3.7); its
  issuer, audience, expiry and nonce are.

  Each service's OAuth client is configured outside the ledger, from the
  environment: `NAME_CLIENT_ID`, `NAME_CLIENT_SECRET` and optionally
  `NAME_REDIRECT_URL` (GOOGLE_CLIENT_ID and so on for the service
  `google`). The redirect URL defaults to the app's public URL plus
  `/auth/NAME/callback`; its path is where the engine takes the callback,
  so an existing client's redirect URL can be reused. Config `:clients`,
  `%{"name" => [client_id: ..., client_secret: ..., redirect_url: ...]}`,
  takes precedence (tests and the local fake use it).
  """

  alias Theseus.{HTTP, Services}

  @type identity :: %{
          provider: String.t(),
          id: String.t(),
          email: String.t() | nil,
          name: String.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          picture: String.t() | nil,
          domain: String.t() | nil
        }

  @doc "A service's OAuth client: `%{client_id, client_secret, redirect_url}`, or nil when not set up."
  @spec client(String.t()) :: map() | nil
  def client(name) do
    config = Map.get(Application.get_env(:theseus, :clients, %{}), name, [])
    env = fn suffix -> present(System.get_env(String.upcase(name) <> suffix)) end

    id = present(config[:client_id]) || env.("_CLIENT_ID")
    secret = present(config[:client_secret]) || env.("_CLIENT_SECRET")

    if id && secret do
      redirect =
        present(config[:redirect_url]) || env.("_REDIRECT_URL") ||
          Theseus.Web.public_url() <> "/auth/#{name}/callback"

      %{client_id: id, client_secret: secret, redirect_url: redirect}
    end
  end

  # A service may name its own redirect address (the review site's sign-in
  # does); otherwise it is the client's.
  defp redirect(service, client), do: Map.get(service, :redirect_url) || client.redirect_url

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  @doc "The service whose callback arrives on this path (as segments), or nil."
  @spec callback_service([String.t()]) :: Services.service() | nil
  def callback_service(path) do
    Services.all()
    |> Map.values()
    |> Enum.find(fn s ->
      (s.sign_in || s.connect) && path == callback_path(s.name)
    end)
  end

  defp callback_path(name) do
    url =
      case client(name) do
        %{redirect_url: url} -> url
        nil -> "/auth/#{name}/callback"
      end

    String.split(URI.parse(url).path || "/", "/", trim: true)
  end

  @doc """
  The URL that sends the person to the service. `flow` is `:sign_in` or
  `:connect`; `fields` has `state`, `nonce`, `challenge` and optionally
  `login_hint`.
  """
  @spec authorize_url(Services.service(), :sign_in | :connect, keyword()) :: String.t()
  def authorize_url(service, flow, fields) do
    client = client(service.name)
    %{scopes: scopes, params: params} = Map.fetch!(service, flow)
    hint = if fields[:login_hint], do: %{"login_hint" => fields[:login_hint]}, else: %{}

    query =
      params
      |> Map.merge(hint)
      |> Map.merge(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect(service, client),
        "response_type" => "code",
        "scope" => Enum.join(scopes, " "),
        "state" => Keyword.fetch!(fields, :state),
        "nonce" => Keyword.fetch!(fields, :nonce),
        "code_challenge" => Keyword.fetch!(fields, :challenge),
        "code_challenge_method" => "S256"
      })

    HTTP.rewrite(service.authorize_url) <> "?" <> URI.encode_query(Enum.sort(query))
  end

  @doc """
  Exchanges the code for tokens. Returns the ID token's claims and the
  tokens: `%{access_token, refresh_token, expires_at, scopes}`, with
  `expires_at` in Unix seconds or nil.
  """
  @spec exchange(Services.service(), String.t(), String.t(), DateTime.t()) ::
          {:ok, map(), map()} | {:error, String.t()}
  def exchange(service, code, verifier, now \\ DateTime.utc_now()) do
    client = client(service.name)

    form = [
      code: code,
      code_verifier: verifier,
      client_id: client.client_id,
      client_secret: client.client_secret,
      redirect_uri: redirect(service, client),
      grant_type: "authorization_code"
    ]

    with {:ok, body} <- token_request(service, form, "the sign-in") do
      with %{"id_token" => token} <- body,
           [_header, payload, _signature] <- String.split(token, "."),
           {:ok, json} <- Base.url_decode64(payload, padding: false),
           {:ok, %{} = claims} <- JSON.decode(json) do
        {:ok, claims, tokens(body, now, [])}
      else
        _ -> {:error, "#{service.name}'s answer held no readable ID token"}
      end
    end
  end

  @doc "A new access token from a refresh token: `{:ok, %{access_token, expires_at}}`."
  @spec refresh(Services.service(), String.t(), DateTime.t()) ::
          {:ok, map()} | {:error, String.t()}
  def refresh(service, refresh_token, now \\ DateTime.utc_now()) do
    case client(service.name) do
      nil ->
        {:error, "#{service.name}'s OAuth client is not set up"}

      client ->
        form = [
          refresh_token: refresh_token,
          client_id: client.client_id,
          client_secret: client.client_secret,
          grant_type: "refresh_token"
        ]

        with {:ok, body} <- token_request(service, form, "renewing access") do
          case body do
            %{"access_token" => token} when is_binary(token) ->
              {:ok, body |> tokens(now, nil) |> Map.take([:access_token, :expires_at])}

            _ ->
              {:error, "#{service.name}'s answer held no access token"}
          end
        end
    end
  end

  @doc "Revokes a token, when the service has a revoke URL. Errors are ignored."
  @spec revoke(Services.service() | nil, String.t() | nil) :: :ok
  def revoke(%{revoke_url: url}, token) when is_binary(url) and is_binary(token) do
    form = URI.encode_query(token: token)
    _ = HTTP.request(:post, url, [], {"application/x-www-form-urlencoded", form})
    :ok
  end

  def revoke(_service, _token), do: :ok

  defp token_request(service, form, what) do
    body = {"application/x-www-form-urlencoded", URI.encode_query(form)}

    case HTTP.request(:post, service.token_url, [{"accept", "application/json"}], body) do
      {:ok, 200, response} ->
        case JSON.decode(response) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> {:error, "#{service.name}'s answer could not be read"}
        end

      {:ok, status, response} ->
        {:error, "#{service.name} refused #{what} (#{status} #{error(response)})"}

      {:error, reason} ->
        {:error, "could not reach #{service.name} (#{inspect(reason)})"}
    end
  end

  defp tokens(body, now, default_scopes) do
    %{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      expires_at:
        if(is_integer(body["expires_in"]), do: DateTime.to_unix(now) + body["expires_in"]),
      scopes:
        case body["scope"] do
          scope when is_binary(scope) -> String.split(scope, " ", trim: true)
          _ -> default_scopes
        end
    }
  end

  defp error(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} ->
        message

      {:ok, %{"error" => error} = map} ->
        Enum.join(Enum.reject([error, map["error_description"]], &is_nil/1), ": ")

      _ ->
        String.slice(body, 0, 200)
    end
  end

  @doc false
  # Checks the ID token's claims (OpenID Connect Core 3.1.3.7) and makes
  # the identity the app's sign_in/1 gets.
  @spec identity(Services.service(), map(), String.t(), DateTime.t()) ::
          {:ok, identity()} | {:error, String.t()}
  def identity(service, claims, nonce, now) do
    aud = List.wrap(claims["aud"])
    client = client(service.name)
    email = is_binary(claims["email"]) && String.downcase(claims["email"])

    cond do
      claims["iss"] not in service.issuers ->
        {:error, "the ID token was not issued by #{service.name}"}

      client == nil or client.client_id not in aud ->
        {:error, "the ID token was issued for another client"}

      not is_integer(claims["exp"]) or claims["exp"] <= DateTime.to_unix(now) ->
        {:error, "the ID token has expired"}

      not is_binary(claims["nonce"]) or not Plug.Crypto.secure_compare(claims["nonce"], nonce) ->
        {:error, "the ID token does not belong to this sign-in"}

      email && claims["email_verified"] != true ->
        {:error, "#{service.name} has not verified this account's email address"}

      true ->
        {:ok,
         %{
           provider: service.name,
           id: claims["sub"],
           email: email || nil,
           name: claims["name"],
           first_name: claims["given_name"],
           last_name: claims["family_name"],
           picture: claims["picture"],
           domain: domain(service, claims, email)
         }}
    end
  end

  defp domain(%{domain_claim: claim}, claims, _email) when is_binary(claim) do
    case claims[claim] do
      value when is_binary(value) and value != "" -> String.downcase(value)
      _ -> nil
    end
  end

  defp domain(_service, _claims, email) when is_binary(email) do
    case String.split(email, "@") do
      [_local, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  defp domain(_service, _claims, _email), do: nil
end
