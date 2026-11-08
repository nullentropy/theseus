defmodule Theseus.App do
  @moduledoc """
  The application's HTTP server: `Theseus.Web` on the app port (config
  `:app`, `PORT`). It starts after Theseus has loaded the live branch.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    config = Application.get_env(:theseus, :app, [])

    children =
      if Keyword.get(config, :server, false),
        do: [
          listener(
            Theseus.Web,
            Keyword.get(config, :ip, {0, 0, 0, 0}),
            Keyword.fetch!(config, :port)
          )
        ],
        else: []

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  # Every HTTP listener the engine runs. HTTP/1.1 only: Theseus serves plain
  # HTTP, where browsers never use HTTP/2. Bandit 1.13.0 fixed the HTTP/2
  # stream pinning (CVE-2026-105659) that first turned it off; turn it on
  # again only for a reason to.
  def listener(plug, ip, port),
    do: {Bandit, plug: plug, ip: ip, port: port, http_2_options: [enabled: false]}
end
