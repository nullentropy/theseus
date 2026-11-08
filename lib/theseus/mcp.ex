defmodule Theseus.MCP do
  @moduledoc """
  The MCP endpoint (Streamable HTTP, `POST /mcp` on the admin port).

  Serves both protocol eras on one endpoint:

    * Modern (2026-07-28): stateless. Every request carries
      `_meta["io.modelcontextprotocol/protocolVersion"]`, mirrored in the
      `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers, which must
      match the body.
    * Legacy (2025-03-26 to 2025-11-25): the client opens with `initialize`.
      Theseus mints an `Mcp-Session-Id` only to remember the client's name for
      attribution; requests without it still work.

  Responses are always single JSON objects, never SSE. Requests whose
  `Origin` header is not local are refused with 403.

  In team mode (`Theseus.Team`) every request carries an engineer's MCP
  token, `Authorization: Bearer tmc_...`, made on the review site; without
  a valid one the answer is 401. Proposals record the engineer, and a token
  tied to a branch makes it the default for tools that take a branch.
  """

  @behaviour Plug

  import Plug.Conn

  alias Theseus.MCP.Tools

  @modern "2026-07-28"
  @legacy ["2025-11-25", "2025-06-18", "2025-03-26"]
  @sessions :theseus_mcp_sessions

  @header_mismatch -32020
  @unsupported_version -32022
  @method_not_found -32601
  @invalid_params -32602
  @invalid_request -32600
  @parse_error -32700

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not local_origin?(conn) ->
        send_json(conn, 403, error_body(nil, @invalid_request, "Origin not allowed"))

      conn.method == "POST" ->
        case who(conn) do
          :ok -> handle_post(conn)
          {:error, why} -> send_json(conn, 401, error_body(nil, @invalid_request, why))
        end

      true ->
        conn |> put_resp_header("allow", "POST") |> send_resp(405, "")
    end
  end

  # Team mode: the engineer behind the request's token acts.
  defp who(conn) do
    if Theseus.Team.mode() == :team do
      with ["Bearer " <> token | _] <- get_req_header(conn, "authorization"),
           {:ok, person, meta} <- Theseus.Team.verify_token(String.trim(token)) do
        Theseus.Team.act_as(person.email)
        Process.put({Theseus.Team, :branch}, meta.branch)
        :ok
      else
        _ -> {:error, "make an MCP token on the review site and send it as a bearer token"}
      end
    else
      :ok
    end
  end

  # When validations were busy, how long this one waited for a sandbox.
  defp queue_note do
    case Theseus.Queue.waited() do
      %{ms: ms, ahead: ahead} when ms >= 1_000 ->
        "\n\nThe validation waited #{div(ms, 1000)} s for a sandbox, behind #{ahead} others."

      _ ->
        ""
    end
  end

  @doc "Supported protocol versions, newest first."
  def versions, do: [@modern | @legacy]

  defp handle_post(conn) do
    {:ok, body, conn} = read_body(conn, length: 4_000_000)

    case JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method} = msg} when is_binary(method) ->
        if Map.has_key?(msg, "id"),
          do: handle_request(conn, msg),
          else: send_resp(conn, 202, "")

      {:ok, _other} ->
        send_json(conn, 400, error_body(nil, @invalid_request, "expected one JSON-RPC request"))

      {:error, _} ->
        send_json(conn, 400, error_body(nil, @parse_error, "invalid JSON"))
    end
  end

  defp handle_request(conn, %{"method" => "initialize"} = msg) do
    params = msg["params"] || %{}
    requested = params["protocolVersion"]
    version = if requested in @legacy, do: requested, else: hd(@legacy)
    session = Base.encode32(:crypto.strong_rand_bytes(15), case: :lower, padding: false)
    remember(session, get_in(params, ["clientInfo", "name"]))

    result = %{
      protocolVersion: version,
      capabilities: %{tools: %{listChanged: false}},
      serverInfo: server_info(),
      instructions: Tools.instructions()
    }

    conn
    |> put_resp_header("mcp-session-id", session)
    |> send_json(200, result_body(msg["id"], result))
  end

  defp handle_request(conn, msg) do
    params = if is_map(msg["params"]), do: msg["params"], else: %{}
    meta = if is_map(params["_meta"]), do: params["_meta"], else: %{}

    case meta["io.modelcontextprotocol/protocolVersion"] do
      nil -> handle_legacy(conn, msg, params)
      version -> handle_modern(conn, msg, params, meta, version)
    end
  end

  defp handle_modern(conn, msg, params, meta, version) do
    client = get_in(meta, ["io.modelcontextprotocol/clientInfo", "name"])

    cond do
      version != @modern ->
        data = %{supported: versions(), requested: version}

        send_json(
          conn,
          400,
          error_body(msg["id"], @unsupported_version, "Unsupported protocol version", data)
        )

      (mismatch = header_mismatch(conn, msg, params, version)) != nil ->
        send_json(
          conn,
          400,
          error_body(msg["id"], @header_mismatch, "Header mismatch: " <> mismatch)
        )

      true ->
        case dispatch(msg["method"], params, client, :modern) do
          {:ok, result} ->
            send_json(conn, 200, result_body(msg["id"], Map.put(result, :resultType, "complete")))

          {:error, @method_not_found, message} ->
            send_json(conn, 404, error_body(msg["id"], @method_not_found, message))

          {:error, code, message} ->
            send_json(conn, 200, error_body(msg["id"], code, message))
        end
    end
  end

  defp handle_legacy(conn, msg, params) do
    header = conn |> get_req_header("mcp-protocol-version") |> List.first()

    if header != nil and header not in @legacy do
      data = %{supported: versions(), requested: header}

      send_json(
        conn,
        400,
        error_body(msg["id"], @unsupported_version, "Unsupported protocol version", data)
      )
    else
      client = conn |> get_req_header("mcp-session-id") |> List.first() |> recall()

      case dispatch(msg["method"], params, client, :legacy) do
        {:ok, result} -> send_json(conn, 200, result_body(msg["id"], result))
        {:error, code, message} -> send_json(conn, 200, error_body(msg["id"], code, message))
      end
    end
  end

  defp dispatch("server/discover", _params, _client, :modern) do
    {:ok,
     %{
       supportedVersions: versions(),
       capabilities: %{tools: %{}},
       _meta: %{"io.modelcontextprotocol/serverInfo" => server_info()},
       instructions: Tools.instructions()
     }}
  end

  defp dispatch("ping", _params, _client, _era), do: {:ok, %{}}
  defp dispatch("tools/list", _params, _client, _era), do: {:ok, %{tools: Tools.definitions()}}

  defp dispatch("tools/call", %{"name" => name} = params, client, _era) when is_binary(name) do
    args = if is_map(params["arguments"]), do: params["arguments"], else: %{}

    # A token tied to a branch works there unless told otherwise.
    args =
      case Process.get({Theseus.Team, :branch}) do
        nil -> args
        branch -> Map.put_new(args, "branch", branch)
      end

    Process.delete({Theseus.Queue, :waited})

    case Tools.call(name, args, client) do
      {:ok, text, structured} ->
        text = text <> queue_note()

        {:ok,
         %{content: [%{type: "text", text: text}], structuredContent: structured, isError: false}}

      {:error, text} ->
        {:ok, %{content: [%{type: "text", text: text}], isError: true}}

      :unknown_tool ->
        {:error, @invalid_params, "Unknown tool: #{name}"}
    end
  end

  defp dispatch("tools/call", _params, _client, _era),
    do: {:error, @invalid_params, "tools/call needs a name"}

  defp dispatch(method, _params, _client, _era),
    do: {:error, @method_not_found, "Method not found: #{method}"}

  defp header_mismatch(conn, msg, params, version) do
    header = fn name -> conn |> get_req_header(name) |> List.first() end

    cond do
      header.("mcp-protocol-version") != version ->
        "MCP-Protocol-Version must be #{version}"

      header.("mcp-method") != msg["method"] ->
        "Mcp-Method must match the request method"

      msg["method"] == "tools/call" and decode_header(header.("mcp-name")) != params["name"] ->
        "Mcp-Name must match params.name"

      true ->
        nil
    end
  end

  defp decode_header("=?base64?" <> rest = value) do
    with true <- String.ends_with?(rest, "?="),
         {:ok, decoded} <- rest |> String.trim_trailing("?=") |> Base.decode64() do
      decoded
    else
      _ -> value
    end
  end

  defp decode_header(value), do: value

  # DNS rebinding protection: browsers send Origin; local tools usually do not.
  # Browsers send Origin; a page elsewhere must not reach a local server.
  # In team mode the review site's own host is allowed too.
  defp local_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        true

      [origin | _] ->
        host = URI.parse(origin).host

        host in ["localhost", "127.0.0.1", "[::1]", "::1"] or
          (Theseus.Team.mode() == :team and host == URI.parse(Theseus.ReviewSignIn.url()).host)
    end
  end

  @doc false
  def sessions_table, do: @sessions

  defp remember(_session, nil), do: :ok

  defp remember(session, name) do
    :ets.insert(@sessions, {session, String.slice(to_string(name), 0, 80)})
  end

  defp recall(nil), do: nil

  defp recall(session) do
    case :ets.lookup(@sessions, session) do
      [{_, name}] -> name
      [] -> nil
    end
  end

  defp server_info, do: %{name: "theseus", version: to_string(Application.spec(:theseus, :vsn))}

  defp result_body(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

  defp error_body(id, code, message, data \\ nil) do
    error = %{code: code, message: message}
    error = if data, do: Map.put(error, :data, data), else: error
    %{jsonrpc: "2.0", id: id, error: error}
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
