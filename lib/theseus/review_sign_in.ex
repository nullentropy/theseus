defmodule Theseus.ReviewSignIn do
  @moduledoc """
  Signs people in to the review site with an OpenID Connect provider, found
  by discovery from its issuer, so no provider is named in the engine. When
  it is set up, the review site is in team mode (`Theseus.Team`).

  Config, from the environment or `config :theseus, :review_sign_in`:

    * `THESEUS_REVIEW_ISSUER` (`issuer`), such as https://accounts.google.com.
    * `THESEUS_REVIEW_CLIENT_ID`, `THESEUS_REVIEW_CLIENT_SECRET`: the OAuth
      client (`Theseus.OAuth.client/1` with the name `theseus_review`).
    * `THESEUS_REVIEW_URL` (`url`): the review site's address, by default
      http://127.0.0.1:<admin port>. The client's redirect address is this
      plus `/sign-in/callback`.
    * `THESEUS_REVIEW_DOMAINS` (`domains`): email domains whose people may
      sign in as engineers without being added.
  """

  alias Theseus.{HTTP, OAuth}

  @client "theseus_review"

  @doc "Whether the review site signs people in."
  @spec configured?() :: boolean()
  def configured?, do: issuer() != nil and OAuth.client(@client) != nil

  @doc "The provider's issuer."
  def issuer, do: present(System.get_env("THESEUS_REVIEW_ISSUER")) || present(config()[:issuer])

  @doc "The review site's address."
  def url do
    present(System.get_env("THESEUS_REVIEW_URL")) || present(config()[:url]) ||
      "http://127.0.0.1:#{Keyword.get(Application.get_env(:theseus, :admin, []), :port, 4001)}"
  end

  @doc """
  The provider as `Theseus.OAuth` takes a service, from its discovery
  document: `{:ok, service}` or `{:error, why}`.
  """
  @spec service() :: {:ok, map()} | {:error, String.t()}
  def service do
    issuer = issuer()

    with {:ok, doc} <- discovered(issuer) do
      {:ok,
       %{
         name: @client,
         authorize_url: doc["authorization_endpoint"],
         token_url: doc["token_endpoint"],
         revoke_url: doc["revocation_endpoint"],
         issuers: Enum.uniq([doc["issuer"] || issuer, issuer]),
         domain_claim: nil,
         sign_in: %{
           scopes: ["openid", "email", "profile"],
           params: %{"prompt" => "select_account"}
         },
         connect: nil,
         urls: [],
         redirect_url: url() <> "/sign-in/callback"
       }}
    end
  end

  # The discovery document, fetched once per issuer.
  defp discovered(issuer) do
    case :persistent_term.get({__MODULE__, issuer}, nil) do
      nil ->
        with {:ok, doc} <- discover(issuer) do
          :persistent_term.put({__MODULE__, issuer}, doc)
          {:ok, doc}
        end

      doc ->
        {:ok, doc}
    end
  end

  defp discover(nil), do: {:error, "THESEUS_REVIEW_ISSUER is not set"}

  defp discover(issuer) do
    address = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    case HTTP.request(:get, address, [{"accept", "application/json"}]) do
      {:ok, 200, body} ->
        case JSON.decode(body) do
          {:ok, %{"authorization_endpoint" => a, "token_endpoint" => t} = doc}
          when is_binary(a) and is_binary(t) ->
            {:ok, doc}

          _ ->
            {:error, "#{issuer}'s discovery document has no authorization and token endpoints"}
        end

      {:ok, status, _} ->
        {:error, "#{issuer} answered #{status} for its discovery document"}

      {:error, reason} ->
        {:error, "could not reach #{issuer} (#{inspect(reason)})"}
    end
  end

  defp present(v) when is_binary(v) and v != "", do: v
  defp present(_), do: nil

  defp config, do: Application.get_env(:theseus, :review_sign_in, [])
end
