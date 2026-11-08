defmodule Theseus.Admin.Forward do
  @moduledoc """
  A follower's admin port (see `Theseus.Leader`): each request is read in
  full and answered by the leader's admin router, over Erlang distribution,
  so the review page and MCP work on every node while the work they start
  runs on the leader. The request keeps its method, path, headers, body and
  the address it came from.
  """

  @behaviour Plug

  require Logger

  @max_body 64_000_000
  @timeout 300_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case read(conn, []) do
      {:ok, body, conn} ->
        request = %{
          method: conn.method,
          scheme: conn.scheme,
          host: conn.host,
          port: conn.port,
          path: conn.request_path,
          query: conn.query_string,
          headers: conn.req_headers,
          remote_ip: conn.remote_ip,
          body: body
        }

        answer(conn, forward(request))

      :too_large ->
        Plug.Conn.send_resp(conn, 413, "request too large")
    end
  end

  defp read(conn, acc) do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, data, conn} ->
        body = IO.iodata_to_binary([acc, data])
        if byte_size(body) > @max_body, do: :too_large, else: {:ok, body, conn}

      {:more, data, conn} ->
        if IO.iodata_length([acc, data]) > @max_body,
          do: :too_large,
          else: read(conn, [acc, data])
    end
  end

  defp forward(request) do
    case Theseus.Leader.node() do
      nil ->
        :unreachable

      leader ->
        :erpc.call(leader, __MODULE__, :serve, [request], @timeout)
    end
  catch
    kind, reason ->
      Logger.warning("the leader did not answer an admin request: #{inspect({kind, reason})}")
      :unreachable
  end

  defp answer(conn, {status, headers, body}) do
    conn
    |> Plug.Conn.merge_resp_headers(Enum.reject(headers, &(elem(&1, 0) == "content-length")))
    |> Plug.Conn.send_resp(status, body)
  end

  defp answer(conn, :unreachable),
    do: Plug.Conn.send_resp(conn, 503, "the node that runs this app's engine cannot be reached")

  @doc false
  # On the leader: runs a follower's request through the admin router and
  # returns `{status, headers, body}`.
  def serve(request) do
    path =
      if request.query in [nil, ""], do: request.path, else: "#{request.path}?#{request.query}"

    conn =
      Plug.Adapters.Test.Conn.conn(%Plug.Conn{}, request.method, path, request.body)
      |> Map.merge(%{
        scheme: request.scheme,
        host: request.host,
        port: request.port,
        req_headers: request.headers,
        remote_ip: request.remote_ip
      })
      |> Plug.Test.put_peer_data(%{address: request.remote_ip, port: 0, ssl_cert: nil})
      |> Theseus.Admin.Router.call(Theseus.Admin.Router.init([]))

    Plug.Test.sent_resp(conn)
  end
end
