defmodule Theseus.HTTP do
  @moduledoc """
  Outbound HTTP from the engine, with OTP's `:httpc`. Certificates and host
  names are verified. Application code cannot call this.

  For local demos, config `:http, rewrite: [{from, to}]` sends URLs that
  start with `from` to `to` instead, such as a service's real address to a
  fake one on this machine (see `config/dev.exs`). Browser redirects to a
  service go through `rewrite/1` too.
  """

  @type headers :: [{String.t(), String.t()}]
  @methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }

  @doc """
  Sends a request. `body` is `{content_type, iodata}` or nil. Returns the
  status and body whatever the status is.
  """
  @spec request(atom(), String.t(), headers(), {String.t(), iodata()} | nil, keyword()) ::
          {:ok, pos_integer(), binary()} | {:error, term()}
  def request(method, url, headers, body \\ nil, opts \\ []) do
    case send_request(method, url, headers, body, opts) do
      {:ok, status, _headers, response} -> {:ok, status, response}
      error -> error
    end
  end

  @doc """
  Sends a request and returns the response headers too, lowercased:
  `{:ok, status, [{name, value}], body}`. `method` is an atom or "GET",
  "POST", "PUT", "PATCH" or "DELETE".
  """
  @spec send_request(
          atom() | String.t(),
          String.t(),
          headers(),
          {String.t(), iodata()} | nil,
          keyword()
        ) ::
          {:ok, pos_integer(), headers(), binary()} | {:error, term()}
  def send_request(method, url, headers, body \\ nil, opts \\ [])

  def send_request(method, url, headers, body, opts) when is_binary(method),
    do: send_request(Map.fetch!(@methods, method), url, headers, body, opts)

  def send_request(method, url, headers, body, opts) do
    headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}
    url = url |> rewrite() |> String.to_charlist()

    request =
      case body do
        nil when method in [:post, :put, :patch] ->
          {url, headers, ~c"application/octet-stream", ""}

        nil ->
          {url, headers}

        {type, data} ->
          {url, headers, String.to_charlist(type), IO.iodata_to_binary(data)}
      end

    http_opts = [timeout: Keyword.get(opts, :timeout, 15_000), ssl: ssl(), autoredirect: false]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, response_headers, response}} ->
        {:ok, status,
         for({k, v} <- response_headers, do: {String.downcase(to_string(k)), to_string(v)}),
         response}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc "The URL a request to `url` actually goes to (see the module doc)."
  @spec rewrite(String.t()) :: String.t()
  def rewrite(url) do
    rules = Keyword.get(Application.get_env(:theseus, :http, []), :rewrite, [])

    Enum.find_value(rules, url, fn {from, to} ->
      if String.starts_with?(url, from),
        do: to <> binary_part(url, byte_size(from), byte_size(url) - byte_size(from))
    end)
  end

  defp ssl do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
