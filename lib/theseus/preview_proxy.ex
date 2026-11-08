defmodule Theseus.PreviewProxy do
  @moduledoc """
  Lets the team reach previews, which listen on 127.0.0.1, through the
  admin port. In team mode, with a preview domain (`THESEUS_PREVIEW_DOMAIN`
  or `previews: [domain: ...]`), a request to `<branch>.<domain>` goes to
  that branch's running preview (an `_` in a branch name is `-` in its
  address). Point a wildcard DNS name and the proxy that serves the review
  site at the admin port.

  Only people on the team get through. Opening a preview from its branch
  page on the review site gives a pass, signed for that person and branch
  and good for 12 hours, which the preview's address keeps in a cookie; an
  agent sends the pass from preview_branch in the `x-theseus-preview`
  header instead. The pass, the cookie and the header never reach the app,
  and a person removed from the team loses access at once.

  The original Host header is kept, and the preview's public address is
  its `PUBLIC_URL`, so its links, redirects, cookies and dev sign-in work
  at that address.
  """

  import Plug.Conn

  alias Theseus.{Keys, Previews, ReviewSignIn, Team}

  @cookie "_theseus_preview"
  @header "x-theseus-preview"
  @salt "theseus preview pass"
  @pass_seconds 12 * 3600
  @hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade content-length)
  @max_body 12_000_000
  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "OPTIONS" => :options,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }

  @doc "The preview domain, when previews are reached through the admin port."
  @spec domain() :: String.t() | nil
  def domain do
    d =
      System.get_env("THESEUS_PREVIEW_DOMAIN") ||
        Keyword.get(Application.get_env(:theseus, :previews, []), :domain)

    if Team.mode() == :team and is_binary(d) and d != "",
      do: d |> String.trim() |> String.trim_leading(".") |> String.downcase()
  end

  @doc "A branch's preview address, when previews go through the admin port, or nil."
  @spec address(String.t()) :: String.t() | nil
  def address(branch) do
    if d = domain() do
      review = URI.parse(ReviewSignIn.url())
      port = if review.port in [nil, 80, 443], do: "", else: ":#{review.port}"
      "#{review.scheme || "http"}://#{label(branch)}.#{d}#{port}"
    end
  end

  @doc "The branch whose preview a host names, or nil."
  @spec branch_for_host(String.t()) :: String.t() | nil
  def branch_for_host(host) do
    with d when is_binary(d) <- domain(),
         [label, rest] <- String.split(String.downcase(host || ""), ".", parts: 2),
         true <- rest == d do
      Enum.find_value(Previews.list(), fn p -> if label(p.branch) == label, do: p.branch end) ||
        {:none, label}
    else
      _ -> nil
    end
  end

  defp label(branch), do: String.replace(branch, "_", "-")

  @doc "A pass to a branch's preview for a person, good for 12 hours."
  @spec pass(String.t(), String.t()) :: String.t()
  def pass(branch, email),
    do: Plug.Crypto.sign(secret(), @salt, %{"b" => branch, "e" => email})

  @doc "The address that opens a branch's preview for a person, with their pass."
  @spec open_url(String.t(), String.t()) :: String.t()
  def open_url(branch, email),
    do:
      address(branch) <> "/_theseus/enter?" <> URI.encode_query(%{"pass" => pass(branch, email)})

  defp secret, do: Base.encode16(Keys.session(), case: :lower)

  @doc """
  A plug for the admin port: requests to a preview's address go to the
  preview; anything else goes on.
  """
  def call(conn, _opts) do
    case branch_for_host(conn.host) do
      nil -> conn
      {:none, label} -> conn |> page(404, "No preview of #{label} is running.") |> halt()
      branch -> conn |> handle(branch) |> halt()
    end
  end

  def init(opts), do: opts

  defp handle(%{path_info: ["_theseus", "enter"]} = conn, branch) do
    conn = fetch_query_params(conn)

    case check(conn.query_params["pass"], branch) do
      {:ok, pass} ->
        conn
        |> put_resp_cookie(@cookie, pass,
          http_only: true,
          same_site: "Lax",
          secure: String.starts_with?(address(branch), "https://"),
          max_age: @pass_seconds
        )
        |> put_resp_header("location", "/")
        |> send_resp(303, "")

      :error ->
        refuse(conn, branch)
    end
  end

  defp handle(conn, branch) do
    conn = fetch_cookies(conn)
    given = List.first(get_req_header(conn, @header)) || conn.cookies[@cookie]

    case check(given, branch) do
      {:ok, _pass} -> forward(conn, branch)
      :error -> refuse(conn, branch)
    end
  end

  defp check(pass, branch) when is_binary(pass) do
    with {:ok, %{"b" => ^branch, "e" => email}} <-
           Plug.Crypto.verify(secret(), @salt, pass, max_age: @pass_seconds),
         %{} <- Team.person(email) do
      {:ok, pass}
    else
      _ -> :error
    end
  end

  defp check(_pass, _branch), do: :error

  defp refuse(conn, branch) do
    page(
      conn,
      403,
      "Open this preview from its branch page: #{ReviewSignIn.url()}/branches/#{branch}"
    )
  end

  defp forward(conn, branch) do
    case Enum.find(Previews.list(), &(&1.branch == branch)) do
      nil ->
        page(conn, 503, "The preview of #{branch} is starting again. Try in a few seconds.")

      _ when not is_map_key(@methods, conn.method) ->
        page(conn, 405, "That method is not supported.")

      %{port: port} ->
        Previews.touch(branch)

        case read_whole_body(conn, []) do
          {:ok, body, conn} -> send_on(conn, port, body)
          :too_large -> page(conn, 413, "The request is too large.")
        end
    end
  end

  defp read_whole_body(conn, acc) do
    case read_body(conn, length: 1_000_000) do
      {:ok, data, conn} ->
        body = IO.iodata_to_binary([acc, data])
        if byte_size(body) > @max_body, do: :too_large, else: {:ok, body, conn}

      {:more, data, conn} ->
        if IO.iodata_length([acc, data]) > @max_body,
          do: :too_large,
          else: read_whole_body(conn, [acc, data])

      {:error, _} ->
        {:ok, IO.iodata_to_binary(acc), conn}
    end
  end

  defp send_on(conn, port, body) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    url = String.to_charlist("http://127.0.0.1:#{port}#{conn.request_path}#{query}")

    headers =
      for {k, v} <- conn.req_headers,
          k not in @hop and k != @header,
          {k, v} = without_pass_cookie({k, v}),
          v != "",
          do: {String.to_charlist(k), String.to_charlist(v)}

    headers = [{~c"x-forwarded-proto", ~c"#{conn.scheme}"} | headers]
    method = Map.get(@methods, conn.method, :get)

    request =
      if method in [:post, :put, :patch, :delete] and body != "" do
        type = List.first(get_req_header(conn, "content-type")) || "application/octet-stream"
        {url, headers, String.to_charlist(type), body}
      else
        {url, headers}
      end

    case :httpc.request(method, request, [timeout: 60_000, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} ->
        conn =
          Enum.reduce(resp_headers, conn, fn {k, v}, conn ->
            k = k |> to_string() |> String.downcase()
            v = to_string(v)

            cond do
              k in @hop -> conn
              k == "set-cookie" -> prepend_resp_headers(conn, [{k, v}])
              true -> put_resp_header(conn, k, v)
            end
          end)

        send_resp(conn, status, resp_body)

      {:error, _reason} ->
        page(conn, 502, "The preview did not answer.")
    end
  end

  # The pass cookie stays here; the app's own cookies go on.
  defp without_pass_cookie({"cookie", value}) do
    kept =
      value
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&String.starts_with?(&1, @cookie <> "="))
      |> Enum.join("; ")

    {"cookie", kept}
  end

  defp without_pass_cookie(header), do: header

  defp page(conn, status, message) do
    html =
      "<!doctype html><meta charset=utf-8><title>Preview</title>" <>
        "<body style=\"font:15px system-ui;margin:3em\"><p>#{Plug.HTML.html_escape(message)}</p></body>"

    conn |> put_resp_content_type("text/html") |> send_resp(status, html)
  end
end
