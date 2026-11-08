defmodule Theseus.Admin do
  @moduledoc """
  The admin port: the MCP endpoint at `/mcp` and the review page at `/`.
  Bound to 127.0.0.1. In team mode (`Theseus.Team`), where people sign in
  and agents send tokens, config `:admin, ip:` (`ADMIN_IP`) may bind it to
  another address, normally behind a proxy that serves it over TLS. Also
  owns the MCP session table and the reviewer token.

  On a follower (`Theseus.Leader`) the port is served too, by handing each
  request to the leader (`Theseus.Admin.Forward`).
  """

  use Supervisor
  require Logger

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Theseus.Leader.follower?(), do: follower(), else: leader()
  end

  # A follower's admin port hands each request to the leader's.
  defp follower do
    config = Application.fetch_env!(:theseus, :admin)

    children =
      if Keyword.fetch!(config, :server),
        do: [
          Theseus.App.listener(Theseus.Admin.Forward, ip(config), Keyword.fetch!(config, :port))
        ],
        else: []

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp leader do
    :ets.new(Theseus.MCP.sessions_table(), [:set, :named_table, :public])
    token = Theseus.Review.new_token()
    config = Application.fetch_env!(:theseus, :admin)

    children =
      if Keyword.fetch!(config, :server) do
        port = Keyword.fetch!(config, :port)

        if Theseus.Team.mode() == :team do
          url = Theseus.ReviewSignIn.url()
          Logger.info("Review site: #{url} (people sign in there)")
          Logger.info("MCP endpoint: #{url}/mcp (with an MCP token made on the review site)")
        else
          Logger.info("MCP endpoint: http://127.0.0.1:#{port}/mcp")

          Logger.info(
            "Review page (opening this link signs you in as reviewer): http://127.0.0.1:#{port}/?token=#{token}"
          )
        end

        [Theseus.App.listener(Theseus.Admin.Router, ip(config), port)]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Another address only in team mode: in local mode the MCP endpoint is
  # open to whoever reaches it.
  defp ip(config) do
    case Keyword.get(config, :ip) do
      nil ->
        {127, 0, 0, 1}

      ip ->
        if Theseus.Team.mode() == :team do
          ip
        else
          Logger.warning(
            "The admin port stays on 127.0.0.1: another address needs review sign-in (THESEUS_REVIEW_ISSUER)"
          )

          {127, 0, 0, 1}
        end
    end
  end
end

defmodule Theseus.Admin.Router do
  @moduledoc false

  use Plug.Router

  plug Theseus.PreviewProxy
  plug :match
  plug :dispatch

  match "/mcp" do
    Theseus.MCP.call(conn, [])
  end

  match _ do
    Theseus.Review.call(conn, Theseus.Review.init([]))
  end
end
