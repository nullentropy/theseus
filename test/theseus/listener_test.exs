defmodule Theseus.ListenerTest do
  @moduledoc "The engine's HTTP listeners speak HTTP/1.1 only (CVE-2026-105659)."

  use ExUnit.Case, async: true

  defmodule Hello do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "hello")
  end

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  # An empty SETTINGS frame: length 0, type 4, no flags, stream 0.
  @settings <<0::24, 4, 0, 0::32>>

  defp start({Bandit, opts}) do
    pid = start_supervised!({Bandit, Keyword.put(opts, :port, 0)}, id: make_ref())
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp first_bytes(port, request) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, request)

    reply =
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, bytes} -> bytes
        {:error, _closed} -> ""
      end

    :gen_tcp.close(socket)
    reply
  end

  # A server speaking HTTP/2 answers the preface with its own SETTINGS frame.
  defp http2?(<<_length::24, 4, _flags, 0::32, _rest::binary>>), do: true
  defp http2?(_reply), do: false

  test "a listener answers HTTP/1.1 and refuses HTTP/2 without TLS" do
    port = start(Theseus.App.listener(Hello, {127, 0, 0, 1}, 0))

    assert first_bytes(port, "GET / HTTP/1.1\r\nhost: x\r\n\r\n") =~ "HTTP/1.1 200"
    refute http2?(first_bytes(port, @preface <> @settings))

    # The same request to a listener with HTTP/2 on, as Bandit's default.
    {Bandit, opts} = Theseus.App.listener(Hello, {127, 0, 0, 1}, 0)
    default = start({Bandit, Keyword.delete(opts, :http_2_options)})
    assert http2?(first_bytes(default, @preface <> @settings))
  end
end
