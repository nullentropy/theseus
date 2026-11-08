defmodule Theseus.Clients do
  @moduledoc """
  API clients of the app, such as an AI assistant using the app's MCP
  server, and the access people grant them (see `Theseus.ClientAuth` for
  the OAuth flow). The engine is the app's OAuth authorization server: a
  client registers itself, a signed-in person lets it act as them, and the
  engine gives it an access token and a refresh token. A request with a
  valid access token reaches the app with `request.user` set to that
  person's user, as a browser session would.

  Tokens are random. The engine keeps only their SHA-256, so the file holds
  nothing a client could use. Access tokens last `access_minutes` (60),
  refresh tokens `refresh_days` (30), both under config `:api_tokens`; each refresh gives a new refresh
  token, and the old one presented again revokes the grant.

  Clients and grants are kept in an encrypted file next to the ledger
  (`<ledger>.clients`, a `Theseus.SealedLog` under the state key, or in the database (see `Theseus.Records`), magic
  `THESEUSK`). Turn it off with `clients_file: false`; they then last until
  a restart. Codes live in memory for a minute.
  """

  use GenServer

  alias Theseus.{Keys, Records}

  @magic "THESEUSK"
  @code_s 60
  @max_clients 1000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The clients file's path."
  def path do
    Application.get_env(:theseus, :clients_path) ||
      Application.fetch_env!(:theseus, :ledger_path) <> ".clients"
  end

  @doc """
  Registers a client (RFC 7591) from its metadata: `client_name` and
  `redirect_uris`. Returns `{:ok, client}` or `{:error, why}`.
  """
  @spec register(map()) :: {:ok, map()} | {:error, String.t()}
  def register(meta), do: GenServer.call(Theseus.Leader.name(__MODULE__), {:register, meta})

  @doc "A registered client, or nil."
  @spec client(term()) :: map() | nil
  def client(id) when is_binary(id),
    do: GenServer.call(Theseus.Leader.name(__MODULE__), {:client, id})

  def client(_id), do: nil

  @doc "A one-time code for a person's consent, as the authorization request asked."
  @spec code(map()) :: String.t()
  def code(fields), do: GenServer.call(Theseus.Leader.name(__MODULE__), {:code, fields})

  @doc """
  Exchanges a code for tokens. `fields` has `code`, `client_id`,
  `redirect_uri` and `code_verifier`. Returns `{:ok, tokens}` or
  `{:error, oauth_error, description}`.
  """
  @spec exchange(map()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def exchange(fields), do: GenServer.call(Theseus.Leader.name(__MODULE__), {:exchange, fields})

  @doc "New tokens for a refresh token. Same answers as exchange/1."
  @spec refresh(String.t(), String.t()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def refresh(token, client_id),
    do: GenServer.call(Theseus.Leader.name(__MODULE__), {:refresh, token, client_id})

  @doc "The person and client an access token stands for: `{:ok, user, client}` or `:error`."
  @spec verify(String.t()) :: {:ok, term(), map()} | :error
  def verify(token) do
    case Theseus.Leader.whereis(__MODULE__) do
      nil -> :error
      pid -> GenServer.call(pid, {:verify, token})
    end
  end

  @doc "Revokes the grant an access or refresh token belongs to (RFC 7009)."
  @spec revoke(String.t()) :: :ok
  def revoke(token), do: GenServer.call(Theseus.Leader.name(__MODULE__), {:revoke_token, token})

  @doc "Revokes a grant by id."
  @spec revoke_grant(String.t()) :: :ok
  def revoke_grant(id), do: GenServer.call(Theseus.Leader.name(__MODULE__), {:revoke_grant, id})

  @doc """
  The grants, without secrets: `%{id, client, user, created_at, last_used}`,
  newest first, where `user` is the person's email address when the user map
  has one.
  """
  @spec grants() :: [map()]
  def grants do
    case Theseus.Leader.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :grants)
    end
  end

  # Server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    {file, records} =
      if Application.get_env(:theseus, :clients_file, true),
        do: Records.open("clients", path(), Keys.state(), @magic, sync: true),
        else: {nil, []}

    {clients, grants} =
      Enum.reduce(records, {%{}, %{}}, fn
        {:client, id, c}, {cs, gs} -> {Map.put(cs, id, c), gs}
        {:grant, id, :deleted}, {cs, gs} -> {cs, Map.delete(gs, id)}
        {:grant, id, g}, {cs, gs} -> {cs, Map.put(gs, id, g)}
      end)

    now = now()
    grants = for {id, g} <- grants, g.refresh_expires > now, into: %{}, do: {id, g}

    file =
      if file,
        do:
          Records.rewrite(
            file,
            for({id, c} <- clients, do: {:client, id, c}) ++
              for({id, g} <- grants, do: {:grant, id, g})
          )

    {:ok, %{file: file, clients: clients, grants: grants, codes: %{}}}
  end

  @impl true
  def handle_call({:register, meta}, _from, state) do
    with :ok <-
           if(map_size(state.clients) < @max_clients, do: :ok, else: {:error, "too many clients"}),
         {:ok, uris} <- redirect_uris(meta["redirect_uris"]),
         {:ok, name} <- client_name(meta["client_name"]) do
      id = "tcl_" <> token(18)
      client = %{id: id, name: name, redirect_uris: uris, created_at: DateTime.utc_now()}
      if state.file, do: Records.append(state.file, {:client, id, client})
      {:reply, {:ok, client}, %{state | clients: Map.put(state.clients, id, client)}}
    else
      {:error, why} -> {:reply, {:error, why}, state}
    end
  end

  def handle_call({:client, id}, _from, state), do: {:reply, state.clients[id], state}

  def handle_call({:code, fields}, _from, state) do
    code = "tco_" <> token(24)
    codes = for {k, c} <- state.codes, c.expires > now(), into: %{}, do: {k, c}
    entry = Map.put(fields, :expires, now() + @code_s)
    {:reply, code, %{state | codes: Map.put(codes, hash(code), entry)}}
  end

  def handle_call({:exchange, f}, _from, state) do
    {entry, codes} = Map.pop(state.codes, hash(f["code"] || ""))
    state = %{state | codes: codes}

    cond do
      entry == nil or entry.expires <= now() ->
        {:reply, {:error, "invalid_grant", "the code is not valid or has expired"}, state}

      entry.client_id != f["client_id"] or entry.redirect_uri != f["redirect_uri"] ->
        {:reply, {:error, "invalid_grant", "the code was given to another client or address"},
         state}

      not is_binary(f["code_verifier"]) or challenge(f["code_verifier"]) != entry.challenge ->
        {:reply, {:error, "invalid_grant", "the code verifier does not match"}, state}

      true ->
        id = "tgr_" <> token(12)
        grant = %{client_id: entry.client_id, user: entry.user, created_at: DateTime.utc_now()}
        {tokens, grant} = new_tokens(grant)
        {:reply, {:ok, tokens}, put_grant(state, id, grant)}
    end
  end

  def handle_call({:refresh, token, client_id}, _from, state) do
    h = hash(token)

    case Enum.find(state.grants, fn {_id, g} -> h in [g.refresh_hash, g[:old_refresh_hash]] end) do
      nil ->
        {:reply, {:error, "invalid_grant", "the refresh token is not valid"}, state}

      {id, %{old_refresh_hash: ^h}} ->
        # A refresh token used twice may have been stolen: end the grant.
        {:reply, {:error, "invalid_grant", "the refresh token was already used"},
         drop_grant(state, id)}

      {_id, g} when g.client_id != client_id ->
        {:reply, {:error, "invalid_grant", "the refresh token belongs to another client"}, state}

      {id, g} ->
        if g.refresh_expires <= now() do
          {:reply, {:error, "invalid_grant", "the refresh token has expired"},
           drop_grant(state, id)}
        else
          {tokens, grant} = new_tokens(Map.put(g, :old_refresh_hash, g.refresh_hash))
          {:reply, {:ok, tokens}, put_grant(state, id, grant)}
        end
    end
  end

  def handle_call({:verify, token}, _from, state) do
    h = hash(token)

    case Enum.find(state.grants, fn {_id, g} -> g.access_hash == h end) do
      {id, g} ->
        if g.access_expires > now() and Map.has_key?(state.clients, g.client_id) do
          client = Map.take(state.clients[g.client_id], [:id, :name])
          g = Map.put(g, :last_used, DateTime.utc_now())
          {:reply, {:ok, g.user, client}, %{state | grants: Map.put(state.grants, id, g)}}
        else
          {:reply, :error, state}
        end

      nil ->
        {:reply, :error, state}
    end
  end

  def handle_call({:revoke_token, token}, _from, state) do
    h = hash(token)

    case Enum.find(state.grants, fn {_id, g} -> h in [g.access_hash, g.refresh_hash] end) do
      {id, _g} -> {:reply, :ok, drop_grant(state, id)}
      nil -> {:reply, :ok, state}
    end
  end

  def handle_call({:revoke_grant, id}, _from, state), do: {:reply, :ok, drop_grant(state, id)}

  def handle_call(:grants, _from, state) do
    list =
      for {id, g} <- state.grants do
        user = if is_map(g.user), do: g.user[:email] || g.user["email"], else: nil
        client = state.clients[g.client_id] || %{name: g.client_id}

        %{
          id: id,
          client: client.name,
          user: user,
          created_at: g.created_at,
          last_used: g[:last_used]
        }
      end

    {:reply, Enum.sort_by(list, & &1.created_at, {:desc, DateTime}), state}
  end

  defp new_tokens(grant) do
    access = "tat_" <> token(32)
    refresh = "trt_" <> token(32)
    access_s = Keyword.get(config(), :access_minutes, 60) * 60
    refresh_s = Keyword.get(config(), :refresh_days, 30) * 86_400

    grant =
      Map.merge(grant, %{
        access_hash: hash(access),
        access_expires: now() + access_s,
        refresh_hash: hash(refresh),
        refresh_expires: now() + refresh_s
      })

    {%{access_token: access, refresh_token: refresh, token_type: "Bearer", expires_in: access_s},
     grant}
  end

  defp put_grant(state, id, grant) do
    if state.file, do: Records.append(state.file, {:grant, id, Map.delete(grant, :last_used)})
    %{state | grants: Map.put(state.grants, id, grant)}
  end

  defp drop_grant(state, id) do
    if state.file && Map.has_key?(state.grants, id),
      do: Records.append(state.file, {:grant, id, :deleted})

    %{state | grants: Map.delete(state.grants, id)}
  end

  # https addresses, or http on this machine (RFC 8252), or an app's own
  # scheme with a dot in it, such as com.example.app:/callback.
  defp redirect_uris(list) when is_list(list) and list != [] and length(list) <= 10 do
    if Enum.all?(list, &redirect_uri?/1),
      do: {:ok, list},
      else: {:error, "redirect_uris must be https, http on localhost, or an app's own scheme"}
  end

  defp redirect_uris(_), do: {:error, "redirect_uris is a list of up to 10 addresses"}

  defp redirect_uri?(uri) when is_binary(uri) and byte_size(uri) <= 2000 do
    case URI.parse(uri) do
      %URI{fragment: f} when f != nil -> false
      %URI{scheme: "https", host: h} when is_binary(h) and h != "" -> true
      %URI{scheme: "http", host: h} -> h in ["localhost", "127.0.0.1", "[::1]", "::1"]
      %URI{scheme: s} when is_binary(s) -> String.contains?(s, ".")
      _ -> false
    end
  end

  defp redirect_uri?(_), do: false

  defp client_name(nil), do: {:ok, "An unnamed client"}

  defp client_name(name) when is_binary(name) do
    name =
      name |> String.replace(~r/[\x00-\x1f\x7f]/, "") |> String.trim() |> String.slice(0, 100)

    {:ok, if(name == "", do: "An unnamed client", else: name)}
  end

  defp client_name(_), do: {:error, "client_name is text"}

  defp challenge(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp token(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp now, do: System.os_time(:second)

  defp config, do: Application.get_env(:theseus, :api_tokens, [])
end
