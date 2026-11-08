defmodule Theseus.Web do
  @moduledoc """
  The application's HTTP server, part of the engine. It takes the sign-in
  requests (`Theseus.SignIn`), turns every other request on the app port
  into a request map and calls the live branch's endpoint unit through
  `Theseus.call/3` (see `Theseus.Endpoint`). With no endpoint unit it
  answers 404 and says so.
  """

  use Plug.Builder
  require Logger

  alias Theseus.{Registry, SignIn}

  plug :parse

  plug :session
  plug :dispatch

  @doc """
  The live root endpoint unit, or nil. An app may split its routes across
  several endpoint units; the root is the one no other unit calls, and it
  hands requests on to the others through `Theseus.call/3`.
  """
  @spec endpoint() :: module() | nil
  def endpoint do
    case for(%{kind: :endpoint} = u <- Registry.units(), do: {u.module, u.current_version}) do
      [] -> nil
      [{module, _}] -> module
      many -> root(Enum.sort(many))
    end
  end

  # Cached until an endpoint unit changes. The root is the endpoint from
  # which every other endpoint can be reached through the calls between
  # them. When none or several can, the previous root is kept if it is a
  # candidate, otherwise the one that reaches the most endpoints.
  defp root(endpoints) do
    case :persistent_term.get({__MODULE__, :root}, nil) do
      {^endpoints, root} ->
        root

      cached ->
        previous = with {_, root} <- cached, do: root
        root = pick_root(endpoints, previous)
        :persistent_term.put({__MODULE__, :root}, {endpoints, root})
        root
    end
  end

  defp pick_root(endpoints, previous) do
    modules = Enum.map(endpoints, &elem(&1, 0))

    calls =
      Map.new(endpoints, fn {m, hash} ->
        refs =
          case Theseus.Ledger.version(m, hash) do
            {:ok, version} -> Theseus.Unit.references(version.ast)
            _ -> MapSet.new()
          end

        {m, Enum.filter(modules, &MapSet.member?(refs, &1))}
      end)

    choose_root(calls, previous)
  end

  @doc false
  # `calls` maps each endpoint unit to the endpoint units it calls. Option
  # `log: false` leaves out the warning when the root is unclear.
  def choose_root(calls, previous, opts \\ []) do
    {modules, reach, covering} = graph(calls)
    log? = Keyword.get(opts, :log, true)

    case covering do
      [one] ->
        one

      [] ->
        unsure(modules, previous, calls, reach, log? && "no endpoint unit reaches all the others")

      several ->
        unsure(
          several,
          previous,
          calls,
          reach,
          log? && "the endpoint units call each other in a cycle"
        )
    end
  end

  @doc """
  The root endpoint unit among `refs` (endpoint unit to the modules it
  names), without logging: for validation and the tools, which may ask for
  a branch that is not live or for endpoint units a change creates.
  `previous` wins a tie.
  """
  @spec root_of(%{module() => MapSet.t()}, module() | nil) :: module() | nil
  def root_of(refs, previous \\ nil) do
    case Map.keys(refs) do
      [] ->
        nil

      [one] ->
        one

      many ->
        calls =
          Map.new(refs, fn {m, names} -> {m, Enum.filter(many, &MapSet.member?(names, &1))} end)

        choose_root(calls, previous, log: false)
    end
  end

  @doc "The root endpoint unit of a branch, or nil when it has none."
  @spec branch_root(String.t()) :: module() | nil
  def branch_root(branch) do
    refs =
      for %{kind: :endpoint, module: m, current_version: h} <- Theseus.Branches.units(branch),
          {:ok, version} <- [Theseus.Ledger.version(m, h)],
          into: %{},
          do: {m, Theseus.Unit.references(version.ast)}

    root_of(refs, if(branch == Theseus.Branches.live(), do: endpoint()))
  end

  @doc false
  # Endpoint units that call each other in a cycle that no other endpoint
  # calls into, so none of them is clearly the root; or nil. Validation
  # refuses a change that leaves the app like this.
  def root_cycle(calls) do
    {modules, reach, _covering} = graph(calls)

    top_cycle =
      modules
      |> Enum.map(fn m ->
        MapSet.new([m | Enum.filter(MapSet.to_list(reach[m]), &MapSet.member?(reach[&1], m))])
      end)
      |> Enum.uniq()
      |> Enum.find(fn cycle ->
        MapSet.size(cycle) > 1 and
          Enum.all?(modules, &(MapSet.member?(cycle, &1) or MapSet.disjoint?(reach[&1], cycle)))
      end)

    if top_cycle, do: top_cycle |> MapSet.to_list() |> Enum.sort()
  end

  # Each endpoint, the endpoints it reaches, and those that reach all the
  # others. When several do, each reaches the others, so they form a cycle.
  defp graph(calls) do
    modules = calls |> Map.keys() |> Enum.sort()
    reach = Map.new(modules, &{&1, reachable(calls, [&1], MapSet.new()) |> MapSet.delete(&1)})
    {modules, reach, Enum.filter(modules, &(MapSet.size(reach[&1]) == length(modules) - 1))}
  end

  defp reachable(_calls, [], seen), do: seen

  defp reachable(calls, [m | rest], seen) do
    if MapSet.member?(seen, m),
      do: reachable(calls, rest, seen),
      else: reachable(calls, Map.get(calls, m, []) ++ rest, MapSet.put(seen, m))
  end

  # The endpoint that reaches the most others wins, then the one that calls
  # the most directly; the previous root wins a tie, so the root does not
  # move between equals.
  defp unsure(candidates, previous, calls, reach, why) do
    score = &{MapSet.size(reach[&1]), length(Map.get(calls, &1, []))}
    best = candidates |> Enum.map(score) |> Enum.max(fn -> nil end)
    top = Enum.filter(candidates, &(score.(&1) == best))
    pick = if previous in top, do: previous, else: List.first(top)

    if why,
      do:
        Logger.warning(
          "#{why}, so the root endpoint is unclear; using #{inspect(pick)}. " <>
            "Make one endpoint unit hand requests on to all the others."
        )

    pick
  end

  @doc """
  The URL people use to reach the app: config `:app, :public_url`
  (`PUBLIC_URL`), or http://localhost and the app port.
  """
  @spec public_url() :: String.t()
  def public_url do
    config = Application.get_env(:theseus, :app, [])

    case config[:public_url] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> "http://localhost:#{Keyword.get(config, :port, 4000)}"
    end
  end

  @conflict {409, :text,
             "The data changed while this was being saved, so nothing was saved. Go back and try again."}

  def session(conn, _opts), do: SignIn.fetch(conn)

  # htmx for the app's pages, served by the engine so pages need no CDN:
  # unpkg.com/htmx.org@2.0.4/dist/htmx.min.js, license 0BSD. The build
  # checks it against htmx's published integrity hash.
  @htmx_file Path.expand("../../priv/static/htmx-2.0.4.min.js", __DIR__)
  @external_resource @htmx_file
  @htmx_js File.read!(@htmx_file)
  @htmx_path "/_theseus/htmx-2.0.4.min.js"

  if Base.encode64(:crypto.hash(:sha384, @htmx_js)) !=
       "HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+",
     do: raise("#{@htmx_file} is not htmx 2.0.4 as published")

  # Bodies are parsed with the upload limit from config (Theseus.Files).
  @doc false
  def parse(conn, _opts) do
    max = Theseus.Files.max_bytes()

    opts =
      case :persistent_term.get({__MODULE__, :parsers}, nil) do
        {^max, opts} ->
          opts

        _ ->
          opts =
            Plug.Parsers.init(
              parsers: [:urlencoded, :json, {:multipart, length: max}],
              json_decoder: JSON,
              pass: ["*/*"]
            )

          :persistent_term.put({__MODULE__, :parsers}, {max, opts})
          opts
      end

    Plug.Parsers.call(conn, opts)
  end

  @doc "The path where the engine serves htmx, for pages to load."
  @spec htmx_path() :: String.t()
  def htmx_path, do: @htmx_path

  def dispatch(%{method: method, request_path: @htmx_path} = conn, _opts)
      when method in ["GET", "HEAD"] do
    conn
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send(200, "text/javascript", @htmx_js)
  end

  def dispatch(conn, _opts) do
    with :pass <- SignIn.route(conn),
         :pass <- Theseus.ClientAuth.route(conn) do
      app(conn, Theseus.ClientAuth.bearer(conn))
    end
  end

  # An API client's bearer token stands for the person who let it in
  # (Theseus.ClientAuth); otherwise the browser session does.
  defp app(conn, :invalid) do
    conn
    |> put_resp_header("www-authenticate", Theseus.ClientAuth.challenge(conn, "invalid_token"))
    |> respond({401, %{error: "invalid_token"}})
  end

  defp app(conn, bearer) do
    {user, csrf, client} =
      case bearer do
        {:ok, user, client} -> {user, nil, client}
        :none -> {SignIn.user(conn), SignIn.csrf_token(conn), nil}
      end

    cond do
      client == nil and not SignIn.csrf_ok?(conn) ->
        respond(conn, {403, %{error: "missing or wrong CSRF token"}})

      unit = endpoint() ->
        request =
          %{
            method: conn.method,
            path: conn.path_info,
            query: conn.query_params,
            body: body(conn),
            user: user,
            csrf_token: csrf,
            now: DateTime.utc_now(),
            # New rows take their ids from it (Theseus.Store.id/2).
            id: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
          }
          |> put_htmx(conn)
          |> then(&if(client, do: Map.put(&1, :client, client), else: &1))

        source = "#{inspect(unit)}.handle #{conn.method} /#{Enum.join(conn.path_info, "/")}"

        try do
          response =
            Theseus.Effects.run(
              source,
              fn -> Theseus.call(unit, :handle, [request]) end,
              @conflict
            )

          hx =
            if get_req_header(conn, "hx-request") == ["true"],
              do: %{self: self_path(conn)}

          # A page answers differently when htmx asks for part of it. A 401
          # tells an API client where to get a token.
          conn
          |> put_resp_header("vary", "HX-Request")
          |> then(
            &if(status(response) == 401,
              do: put_resp_header(&1, "www-authenticate", Theseus.ClientAuth.challenge(&1)),
              else: &1
            )
          )
          |> respond(for_htmx(response, request, hx))
        rescue
          _ -> respond(conn, {500, %{error: "internal error"}})
        catch
          _, _ -> respond(conn, {500, %{error: "internal error"}})
        end

      true ->
        respond(conn, {404, %{error: "this app has no endpoint unit yet"}})
    end
  end

  defp status({:htmx, _headers, inner}), do: status(inner)
  defp status({status, _}) when is_integer(status), do: status
  defp status({status, _, _}) when is_integer(status), do: status
  defp status(_response), do: nil

  # htmx sends HX-* headers with every request it makes. The unit gets them
  # as `htmx` only when htmx wants part of a page: boosted links and forms,
  # and history restores, want the whole page and look like any other
  # request. The values come from the browser, like the query.
  defp put_htmx(request, conn) do
    # htmx URI-encodes a value a header cannot carry, and says so.
    header = fn name ->
      value = List.first(get_req_header(conn, name))

      if value && get_req_header(conn, name <> "-uri-autoencoded") == ["true"],
        do: URI.decode(value),
        else: value
    end

    if header.("hx-request") == "true" and header.("hx-boosted") != "true" and
         header.("hx-history-restore-request") != "true" do
      Map.put(request, :htmx, %{
        target: short(header.("hx-target")),
        trigger: short(header.("hx-trigger")),
        trigger_name: short(header.("hx-trigger-name")),
        current_path: current_path(header.("hx-current-url")),
        prompt: short(header.("hx-prompt"))
      })
    else
      request
    end
  end

  defp short(value) when is_binary(value) and value != "" do
    if String.valid?(value), do: String.slice(value, 0, 200)
  end

  defp short(_value), do: nil

  # The page htmx was on, as a path with its query.
  defp current_path(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: "/" <> _ = path, query: query} ->
        short(if query, do: path <> "?" <> query, else: path)

      _ ->
        nil
    end
  end

  defp current_path(_url), do: nil

  @doc false
  # How an answer goes back to htmx. `request` is what the unit got; `hx` is
  # nil unless htmx sent the request (boosted links and forms included), and
  # then holds the request's own path.
  #
  #   * A download goes back as HX-Redirect to the same GET, so the browser
  #     fetches it as a file; htmx would put the file's text in the page.
  #   * A redirect that answers a request for part of a page becomes
  #     HX-Redirect: htmx would put the whole next page where the part goes.
  #   * A boosted form that answers with a page instead of a redirect (its
  #     errors, say) leaves the address bar alone, since reloading would GET
  #     the address the form posted to.
  def for_htmx(response, _request, nil), do: response

  def for_htmx(response, request, %{self: self}) do
    cond do
      request.method == "GET" and match?({_, {:download, _, _}, _}, innermost(response)) ->
        {:htmx, %{redirect: self}, {200, :text, ""}}

      Map.has_key?(request, :htmx) ->
        htmx_redirect(response)

      request.method != "GET" and not match?({:redirect, _}, innermost(response)) ->
        {:htmx, %{push_url: false}, response}

      true ->
        response
    end
  end

  defp htmx_redirect({:redirect, path}), do: {:htmx, %{redirect: path}, {200, :text, ""}}
  defp htmx_redirect({:htmx, headers, inner}), do: {:htmx, headers, htmx_redirect(inner)}
  defp htmx_redirect(response), do: response

  defp innermost({:htmx, _headers, inner}), do: innermost(inner)
  defp innermost(response), do: response

  defp self_path(%{request_path: path, query_string: ""}), do: path
  defp self_path(%{request_path: path, query_string: query}), do: path <> "?" <> query

  defp body(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  # Always a map for JSON and forms, so `body["field"]` never raises: a JSON
  # value that is not an object stays under "_json", as Plug puts it.
  # Uploaded files are kept by the engine and passed on as references
  # (Theseus.Files).
  defp body(%{body_params: params}), do: params |> Map.delete("_csrf") |> Theseus.Files.take()

  @doc false
  # A redirect to another site, for the engine only (endpoint units may only
  # redirect within the site). htmx, as for a boosted sign-in link, cannot
  # follow it inside its request, so the browser is told to go there itself.
  def respond_external(conn, url) do
    if get_req_header(conn, "hx-request") == ["true"],
      do: conn |> put_resp_header("hx-redirect", url) |> send_resp(200, ""),
      else: conn |> put_resp_header("location", url) |> send_resp(302, "")
  end

  @doc "Sends an endpoint response (see `Theseus.Endpoint`)."
  @spec respond(Plug.Conn.t(), term()) :: Plug.Conn.t()

  def respond(conn, {status, :html, html}) when is_integer(status) and is_binary(html),
    do: send(conn, status, "text/html", html)

  def respond(conn, {status, :text, text}) when is_integer(status) and is_binary(text),
    do: send(conn, status, "text/plain", text)

  def respond(conn, {status, {:download, filename, type}, data})
      when is_integer(status) and is_binary(filename) and is_binary(data) do
    case {download_type(type), download_name(filename)} do
      {nil, _} ->
        send(conn, 500, "application/json", ~s({"error":"downloads are CSV, plain text or JSON"}))

      {_, nil} ->
        send(conn, 500, "application/json", ~s({"error":"the download has no usable file name"}))

      {content_type, name} ->
        conn
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send(status, content_type, data)
    end
  end

  def respond(conn, {status, {:upload, id}}) when is_integer(status) do
    case Theseus.Files.get(id) do
      {:ok, file} ->
        disposition = if Theseus.Files.inline?(file.type), do: "inline", else: "attachment"

        conn
        |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{file.name}"))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> send(status, file.type, file.data)

      :error ->
        send(conn, 404, "application/json", ~s({"error":"no such file"}))
    end
  end

  def respond(conn, {:redirect, path}) when is_binary(path) do
    case SignIn.local_path(path) do
      nil ->
        send(conn, 500, "application/json", ~s({"error":"the endpoint redirected off this site"}))

      path ->
        # After a form post, 303 makes the browser follow with a GET.
        status = if conn.method in ["GET", "HEAD"], do: 302, else: 303

        conn
        |> put_resp_header("location", path)
        |> send_resp(status, "")
    end
  end

  def respond(conn, {:htmx, headers, response}) do
    case htmx_headers(headers) do
      {:ok, pairs} ->
        pairs
        |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
        |> respond(response)

      {:error, why} ->
        message = "the endpoint returned htmx headers that are not valid: #{why}"
        send(conn, 500, "application/json", JSON.encode!(%{error: message}))
    end
  end

  def respond(conn, {status, body}) when is_integer(status) do
    send(conn, status, "application/json", JSON.encode!(body))
  rescue
    _ -> send(conn, 500, "application/json", ~s({"error":"the response is not JSON"}))
  end

  def respond(conn, _other),
    do: send(conn, 500, "application/json", ~s({"error":"the endpoint returned no response"}))

  @htmx_headers %{
    trigger: "hx-trigger",
    trigger_after_settle: "hx-trigger-after-settle",
    trigger_after_swap: "hx-trigger-after-swap",
    retarget: "hx-retarget",
    reswap: "hx-reswap",
    reselect: "hx-reselect",
    push_url: "hx-push-url",
    replace_url: "hx-replace-url",
    redirect: "hx-redirect",
    location: "hx-location",
    refresh: "hx-refresh"
  }

  @doc """
  The response headers for an endpoint's `{:htmx, headers, response}`, or
  why they are not valid. `headers` is a map or keyword list (see
  `Theseus.Endpoint`).
  """
  @spec htmx_headers(term()) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def htmx_headers(headers) when is_map(headers) or is_list(headers) do
    if is_list(headers) and not Keyword.keyword?(headers) do
      {:error, "they must be a map or a keyword list"}
    else
      Enum.reduce_while(headers, {:ok, []}, fn {key, value}, {:ok, acc} ->
        case htmx_header(key, value) do
          {:ok, header} -> {:cont, {:ok, [header | acc]}}
          {:error, why} -> {:halt, {:error, why}}
        end
      end)
      |> then(fn
        {:ok, pairs} -> {:ok, Enum.sort(pairs)}
        error -> error
      end)
    end
  end

  def htmx_headers(_headers), do: {:error, "they must be a map or a keyword list"}

  defp htmx_header(key, value) when is_map_key(@htmx_headers, key) do
    with {:ok, text} <- htmx_value(key, value) do
      if String.match?(text, ~r/^[\x20-\x7e]{0,1000}$/),
        do: {:ok, {@htmx_headers[key], text}},
        else: {:error, "#{key} must be plain text without line breaks, up to 1000 characters"}
    end
  end

  defp htmx_header(key, _value) do
    keys = @htmx_headers |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    {:error, "#{inspect(key)} is not one of #{keys}"}
  end

  defp htmx_value(key, value)
       when key in [:trigger, :trigger_after_settle, :trigger_after_swap] do
    case value do
      name when is_binary(name) ->
        {:ok, name}

      %{} = events ->
        # Event details go as JSON. Non-ASCII text is escaped, since header
        # values are ASCII.
        try do
          {:ok, events |> JSON.encode!() |> ascii_json()}
        rescue
          _ -> {:error, "#{key} details must be JSON: strings, numbers, lists and maps"}
        end

      _ ->
        {:error, "#{key} is an event name or a map of event names to details"}
    end
  end

  defp htmx_value(key, value) when key in [:retarget, :reswap, :reselect] do
    if is_binary(value), do: {:ok, value}, else: {:error, "#{key} is a string"}
  end

  defp htmx_value(key, false) when key in [:push_url, :replace_url], do: {:ok, "false"}

  defp htmx_value(key, value) when key in [:push_url, :replace_url, :redirect, :location] do
    case SignIn.local_path(value) do
      nil -> {:error, "#{key} must be a path on this site, such as \"/people\""}
      path -> {:ok, path}
    end
  end

  defp htmx_value(:refresh, true), do: {:ok, "true"}
  defp htmx_value(:refresh, _value), do: {:error, "refresh is true"}

  defp ascii_json(json) do
    for <<c::utf8 <- json>>, into: "" do
      cond do
        c < 0x80 ->
          <<c>>

        c < 0x10000 ->
          "\\u" <> hex4(c)

        true ->
          c = c - 0x10000

          "\\u" <>
            hex4(0xD800 + Bitwise.bsr(c, 10)) <> "\\u" <> hex4(0xDC00 + Bitwise.band(c, 0x3FF))
      end
    end
  end

  defp hex4(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")

  @download_types %{
    "text/csv" => "text/csv",
    "text/plain" => "text/plain",
    "application/json" => "application/json"
  }

  defp download_type(type), do: @download_types[type]

  # Letters, digits, dots, dashes and underscores, not starting with a dot.
  defp download_name(name) do
    clean = String.replace(name, ~r/[^A-Za-z0-9._-]/, "_")
    if clean != "" and not String.starts_with?(clean, ".") and byte_size(clean) <= 100, do: clean
  end

  defp send(conn, status, type, body) do
    conn
    |> put_resp_content_type(type)
    |> send_resp(status, body)
  end
end
