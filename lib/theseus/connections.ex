defmodule Theseus.Connections do
  @moduledoc """
  The app's connections to outside services, one per service and domain.
  An admin connects a service the app declares with `connect`
  (`Theseus.Services`) at `/auth/NAME/connect` (see `Theseus.SignIn`); the
  engine keeps the tokens, renews the access token when it is about to
  expire, and adds it to the app's requests to that service
  (`Theseus.Fetch`). The app never sees a token.

  The engine tells the app about connections through the root endpoint
  unit's optional `connection/1`, called like any callback:

      %{event: :connected, service: "google", domain: "acme.com", by: "ada@acme.com", scopes: [...], now: now, id: id}
      %{event: :disconnected, service: "google", domain: "acme.com", by: "ada@acme.com", now: now, id: id}

  Connections are kept in an encrypted file next to the ledger
  (`<ledger>.connections`, a `Theseus.SealedLog` under the state key, or in the database (see `Theseus.Records`), magic
  `THESEUSC`). Turn it off with `connections_file: false`; connections then
  last until a restart.
  """

  use GenServer
  require Logger

  alias Theseus.{Keys, OAuth, Records, Services}

  @magic "THESEUSC"
  # An access token this close to expiry is renewed before it is used.
  @margin_s 60

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The connections file's path."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:theseus, :connections_path) ||
      Application.fetch_env!(:theseus, :ledger_path) <> ".connections"
  end

  @doc """
  Records a new connection of `service` for `identity.domain`, made by
  `identity.email`, and tells the app. `tokens` is `%{access_token,
  refresh_token, expires_at, scopes}`.
  """
  @spec connect(String.t(), map(), map()) :: :ok
  def connect(service, identity, tokens),
    do:
      GenServer.call(
        Theseus.Leader.name(__MODULE__),
        {:connect, service, identity, tokens},
        30_000
      )

  @doc "Removes a connection, revokes its token, and tells the app."
  @spec disconnect(String.t(), String.t(), String.t() | nil) :: :ok | {:error, :not_connected}
  def disconnect(service, domain, by),
    do:
      GenServer.call(Theseus.Leader.name(__MODULE__), {:disconnect, service, domain, by}, 30_000)

  @doc """
  A current access token for a connection, renewed first when it is about
  to expire, or with `renew: true`.
  """
  @spec token(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def token(service, domain, opts \\ []) do
    case Theseus.Leader.whereis(__MODULE__) do
      nil -> {:error, "connections are not running"}
      pid -> GenServer.call(pid, {:token, service, domain, opts[:renew] == true}, 30_000)
    end
  end

  @doc "Notes how the latest request on a connection went, for the review page."
  @spec used(String.t(), String.t(), pos_integer() | String.t()) :: :ok
  def used(service, domain, status),
    do: GenServer.cast(Theseus.Leader.name(__MODULE__), {:used, service, domain, status})

  @doc """
  The connections, without secrets: `%{service, domain, connected_by,
  connected_at, scopes, last_used}`, where `last_used` is `%{at, status}`
  or nil.
  """
  @spec list() :: [map()]
  def list do
    case Theseus.Leader.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :list)
    end
  end

  # Server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    {file, conns} =
      if Application.get_env(:theseus, :connections_file, true) do
        {file, records} = Records.open("connections", path(), Keys.state(), @magic, sync: true)

        conns =
          Enum.reduce(records, %{}, fn
            {:connection, {_s, _d} = key, :deleted}, acc -> Map.delete(acc, key)
            {:connection, {_s, _d} = key, conn}, acc -> Map.put(acc, key, conn)
            # A connection kept before connections named their service.
            {:connection, domain, _old}, acc when is_binary(domain) -> acc
          end)

        dropped = length(for {:connection, d, _} <- records, is_binary(d), do: d)

        if dropped > 0,
          do:
            Logger.warning(
              "dropped #{dropped} connection records from before services; connect again"
            )

        {Records.rewrite(file, for({k, c} <- conns, do: {:connection, k, c})), conns}
      else
        {nil, %{}}
      end

    {:ok, %{file: file, conns: conns}}
  end

  @impl true
  def handle_call({:connect, service, identity, tokens}, _from, state) do
    key = {service, identity.domain}

    # A connection being replaced gives up its grant.
    with %{tokens: %{refresh_token: old}} when is_binary(old) and old != tokens.refresh_token <-
           state.conns[key] do
      revoke_later(service, old)
    end

    conn = %{
      service: service,
      domain: identity.domain,
      connected_by: identity.email,
      connected_at: DateTime.utc_now(),
      tokens: tokens,
      last_used: nil
    }

    state = put(state, key, conn)

    tell_app(%{
      event: :connected,
      service: service,
      domain: identity.domain,
      by: identity.email,
      scopes: tokens.scopes || []
    })

    {:reply, :ok, state}
  end

  def handle_call({:disconnect, service, domain, by}, _from, state) do
    key = {service, domain}

    case state.conns[key] do
      nil ->
        {:reply, {:error, :not_connected}, state}

      conn ->
        revoke_later(service, conn.tokens.refresh_token || conn.tokens.access_token)
        if state.file, do: Records.append(state.file, {:connection, key, :deleted})
        tell_app(%{event: :disconnected, service: service, domain: domain, by: by})
        {:reply, :ok, %{state | conns: Map.delete(state.conns, key)}}
    end
  end

  def handle_call({:token, service, domain, renew?}, _from, state) do
    key = {service, domain}

    case state.conns[key] do
      nil ->
        {:reply, {:error, "#{service} is not connected for #{domain}"}, state}

      conn ->
        now = DateTime.to_unix(DateTime.utc_now())
        at = conn.tokens.expires_at

        if not renew? and is_binary(conn.tokens.access_token) and
             (at == nil or at - @margin_s > now) do
          {:reply, {:ok, conn.tokens.access_token}, state}
        else
          case renewed(service, conn) do
            {:ok, tokens} ->
              {:reply, {:ok, tokens.access_token}, put(state, key, %{conn | tokens: tokens})}

            {:error, why} ->
              {:reply, {:error, why}, state}
          end
        end
    end
  end

  def handle_call(:list, _from, state) do
    list =
      for {_key, c} <- state.conns do
        c
        |> Map.take([:service, :domain, :connected_by, :connected_at, :last_used])
        |> Map.put(:scopes, c.tokens.scopes || [])
      end

    {:reply, Enum.sort_by(list, &{&1.service, &1.domain}), state}
  end

  @impl true
  def handle_cast({:used, service, domain, status}, state) do
    key = {service, domain}

    case state.conns[key] do
      nil ->
        {:noreply, state}

      conn ->
        # Kept in memory only: the file is written when the tokens change.
        conn = %{conn | last_used: %{at: DateTime.utc_now(), status: status}}
        {:noreply, %{state | conns: Map.put(state.conns, key, conn)}}
    end
  end

  defp renewed(service, conn) do
    with %{} = s <- Services.get(service) || {:error, "the app no longer declares #{service}"},
         refresh when is_binary(refresh) <-
           conn.tokens.refresh_token ||
             {:error, "#{service} gave no refresh token; connect #{conn.domain} again"},
         {:ok, fresh} <- OAuth.refresh(s, refresh) do
      {:ok, Map.merge(conn.tokens, fresh)}
    end
  end

  defp revoke_later(service, token) do
    Task.Supervisor.start_child(Theseus.TaskSupervisor, fn ->
      OAuth.revoke(Services.get(service), token)
    end)
  end

  defp put(state, key, conn) do
    if state.file, do: Records.append(state.file, {:connection, key, conn})
    %{state | conns: Map.put(state.conns, key, conn)}
  end

  # Tells the app outside this process: the app's callback may make
  # requests, which ask this process for tokens.
  defp tell_app(event) do
    Task.Supervisor.start_child(Theseus.TaskSupervisor, fn ->
      event = Map.merge(event, %{now: DateTime.utc_now(), id: Theseus.Effects.new_id()})

      case Theseus.Effects.callback(:connection, event) do
        {:error, why} -> Logger.warning("the app's connection/1 failed: #{why}")
        _ -> :ok
      end
    end)
  end
end
