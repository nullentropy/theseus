defmodule Theseus.Services do
  @moduledoc """
  The outside services an app uses, declared in a services unit: a pure
  unit that does `use Theseus.Services` and defines `services/0` returning
  a literal map. The engine reads it from the syntax tree, as it reads
  schema units, and never runs it.

      defmodule App.Services do
        use Theseus.Services

        def services do
          %{
            google: %{
              authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
              token_url: "https://oauth2.googleapis.com/token",
              revoke_url: "https://oauth2.googleapis.com/revoke",
              issuers: ["https://accounts.google.com", "accounts.google.com"],
              domain_claim: "hd",
              sign_in: %{scopes: ["openid", "email", "profile"], params: %{prompt: "select_account"}},
              connect: %{
                scopes: ["openid", "email", "https://www.googleapis.com/auth/admin.directory.user.readonly"],
                required_scopes: ["https://www.googleapis.com/auth/admin.directory.user.readonly"],
                params: %{access_type: "offline", prompt: "consent"}
              },
              urls: ["https://admin.googleapis.com/admin/directory/v1/"]
            }
          }
        end
      end

  A service's name is a lowercase atom: people sign in at `/auth/NAME`,
  and its OAuth client comes from `NAME_CLIENT_ID` and `NAME_CLIENT_SECRET`
  (see `Theseus.OAuth`). Its fields, all optional:

    * `urls`: where the app's requests to the service may go (see
      `Theseus.Fetch`), each the start of an https URL ending in `/`. A
      request anywhere else is refused.
    * `authorize_url`, `token_url`: its OAuth 2.0 endpoints, needed for
      `sign_in` and `connect`; `revoke_url`, where a connection's token is
      given up when it is disconnected or replaced.
    * `issuers`: who may issue its OpenID Connect ID tokens.
    * `domain_claim`: the ID token claim naming the person's organization,
      such as Google's `"hd"`; the domain is nil when the claim is missing.
      Without it, the domain is the email address's.
    * `sign_in`: people may sign in with it. `scopes` must include
      "openid"; `params` are added to the authorization request.
    * `connect`: an admin may connect it for their domain at
      `/auth/NAME/connect`, and the engine keeps the token and sends it
      with the app's requests. `scopes` must include "openid", so the
      engine learns the domain; `required_scopes` must all be granted.

  Services change through proposals like any unit, and a person decides
  every change to them: they say where the app's requests may go and what
  access it asks people for.
  """

  alias Theseus.{Branches, Ledger}

  @callback services() :: map()

  defmacro __using__(_opts) do
    quote do
      @behaviour Theseus.Services
    end
  end

  @name ~r/^[a-z][a-z0-9_]{0,29}$/
  # Paths under /auth the engine takes for itself.
  @taken ["dev", "logout"]
  @fields [
    :urls,
    :authorize_url,
    :token_url,
    :revoke_url,
    :issuers,
    :domain_claim,
    :sign_in,
    :connect
  ]
  # The engine sets these on every authorization request.
  @reserved_params ~w(client_id redirect_uri response_type scope state nonce code_challenge code_challenge_method)

  @type service :: %{
          name: String.t(),
          urls: [String.t()],
          authorize_url: String.t() | nil,
          token_url: String.t() | nil,
          revoke_url: String.t() | nil,
          issuers: [String.t()],
          domain_claim: String.t() | nil,
          sign_in: %{scopes: [String.t()], params: %{String.t() => String.t()}} | nil,
          connect:
            %{
              scopes: [String.t()],
              required_scopes: [String.t()],
              params: %{String.t() => String.t()}
            }
            | nil
        }

  @doc "Whether a unit's syntax tree is a services unit's."
  @spec services_unit?(Macro.t()) :: boolean()
  def services_unit?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:Theseus, :Services]} | _]} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  @doc "The services a services unit declares, read from its syntax tree."
  @spec from_ast(Macro.t()) :: {:ok, %{String.t() => service()}} | {:error, String.t()}
  def from_ast({:defmodule, _, [_name, [do: body]]}) do
    statements =
      case body do
        {:__block__, _, statements} -> statements
        statement -> [statement]
      end

    bodies =
      for {:def, _, [{:services, _, args}, [do: value]]} <- statements,
          args in [nil, []],
          do: value

    case bodies do
      [value] ->
        case Theseus.Schema.literal(value) do
          {:ok, term} -> normalize(term)
          :error -> {:error, "services/0 must return a literal map, with no variables or calls"}
        end

      [] ->
        {:error, "a services unit defines services/0"}

      _ ->
        {:error, "services/0 is defined more than once"}
    end
  end

  def from_ast(_ast), do: {:error, "a services unit is one defmodule"}

  @doc "Checks and normalises a `services/0` value."
  @spec normalize(term()) :: {:ok, %{String.t() => service()}} | {:error, String.t()}
  def normalize(services) when is_map(services) do
    Enum.reduce_while(services, {:ok, %{}}, fn {name, fields}, {:ok, acc} ->
      case service(name, fields) do
        {:ok, s} -> {:cont, {:ok, Map.put(acc, s.name, s)}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
  end

  def normalize(_services), do: {:error, "services/0 returns a map of service names to services"}

  defp service(name, fields) when is_atom(name) and is_map(fields) do
    name = Atom.to_string(name)
    unknown = Map.keys(fields) -- @fields

    with :ok <-
           must(
             name not in @taken,
             "#{name} is a path the engine takes; name the service otherwise"
           ),
         :ok <-
           must(
             Regex.match?(@name, name),
             "#{inspect(name)} is not a service name: lowercase letters, digits and _"
           ),
         :ok <-
           must(
             unknown == [],
             "#{name} has unknown fields: #{Enum.map_join(unknown, ", ", &inspect/1)}"
           ),
         {:ok, urls} <- prefixes(name, Map.get(fields, :urls, [])),
         {:ok, authorize} <- optional_url(name, :authorize_url, fields),
         {:ok, token} <- optional_url(name, :token_url, fields),
         {:ok, revoke} <- optional_url(name, :revoke_url, fields),
         {:ok, issuers} <- texts(name, :issuers, Map.get(fields, :issuers, [])),
         {:ok, claim} <- optional_text(name, :domain_claim, fields),
         {:ok, sign_in} <- flow(name, :sign_in, fields[:sign_in], [:scopes, :params]),
         {:ok, connect} <-
           flow(name, :connect, fields[:connect], [:scopes, :required_scopes, :params]),
         :ok <-
           must(
             (sign_in == nil and connect == nil) or
               (authorize != nil and token != nil and issuers != []),
             "#{name} signs people in or connects, so it needs authorize_url, token_url and issuers"
           ) do
      {:ok,
       %{
         name: name,
         urls: urls,
         authorize_url: authorize,
         token_url: token,
         revoke_url: revoke,
         issuers: issuers,
         domain_claim: claim,
         sign_in: sign_in,
         connect: connect
       }}
    end
  end

  defp service(name, _fields),
    do: {:error, "#{inspect(name)}: a service is a name (an atom) and a map of fields"}

  defp flow(_name, _key, nil, _allowed), do: {:ok, nil}

  defp flow(name, key, fields, allowed) when is_map(fields) do
    unknown = Map.keys(fields) -- allowed

    with :ok <-
           must(
             unknown == [],
             "#{name}'s #{key} has unknown fields: #{Enum.map_join(unknown, ", ", &inspect/1)}"
           ),
         {:ok, scopes} <- texts(name, :scopes, Map.get(fields, :scopes, [])),
         :ok <- must("openid" in scopes, "#{name}'s #{key} scopes must include \"openid\""),
         {:ok, required} <- texts(name, :required_scopes, Map.get(fields, :required_scopes, [])),
         :ok <-
           must(
             Enum.all?(required, &(&1 in scopes)),
             "#{name}'s required_scopes must be among its #{key} scopes"
           ),
         {:ok, params} <- params(name, Map.get(fields, :params, %{})) do
      base = %{scopes: scopes, params: params}

      {:ok,
       if(:required_scopes in allowed, do: Map.put(base, :required_scopes, required), else: base)}
    end
  end

  defp flow(name, key, _fields, _allowed), do: {:error, "#{name}'s #{key} is a map"}

  defp params(name, params) when is_map(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      key = to_string(k)

      cond do
        not ((is_atom(k) or is_binary(k)) and is_binary(v)) ->
          {:halt, {:error, "#{name}'s params map names to text"}}

        key in @reserved_params ->
          {:halt, {:error, "#{name}'s params may not set #{key}: the engine sets it"}}

        true ->
          {:cont, {:ok, Map.put(acc, key, v)}}
      end
    end)
  end

  defp params(name, _params), do: {:error, "#{name}'s params is a map"}

  defp prefixes(name, list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn url, {:ok, acc} ->
      if https?(url) and String.ends_with?(url, "/"),
        do: {:cont, {:ok, acc ++ [url]}},
        else:
          {:halt,
           {:error, "#{name}'s urls are starts of https URLs ending in /, not #{inspect(url)}"}}
    end)
  end

  defp prefixes(name, _list), do: {:error, "#{name}'s urls is a list"}

  defp optional_url(name, key, fields) do
    case Map.get(fields, key) do
      nil -> {:ok, nil}
      url -> if https?(url), do: {:ok, url}, else: {:error, "#{name}'s #{key} is an https URL"}
    end
  end

  defp optional_text(name, key, fields) do
    case Map.get(fields, key) do
      nil -> {:ok, nil}
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:error, "#{name}'s #{key} is text"}
    end
  end

  defp texts(name, key, list) do
    if is_list(list) and Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: {:ok, list},
      else: {:error, "#{name}'s #{key} is a list of text"}
  end

  defp https?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp https?(_url), do: false

  defp must(true, _why), do: :ok
  defp must(false, why), do: {:error, why}

  ## The live services

  @doc "The services units on a branch and what they declare: `[{module, services}]`."
  @spec units(String.t()) :: [{module(), %{String.t() => service()}}]
  def units(branch) do
    Ledger.memo({:services_units, branch}, fn ->
      for u <- Branches.units(branch),
          {:ok, %{ast: ast}} <- [Ledger.version(u.module, u.current_version)],
          ast != nil and services_unit?(ast),
          {:ok, services} <- [from_ast(ast)],
          do: {u.module, services}
    end)
  end

  @doc "Every service the live branch declares, by name."
  @spec all() :: %{String.t() => service()}
  def all do
    Branches.live() |> units() |> Enum.map(&elem(&1, 1)) |> Enum.reduce(%{}, &Map.merge(&2, &1))
  rescue
    # Before the ledger is up there are no services.
    _ -> %{}
  end

  @doc "A live service by name, or nil."
  @spec get(String.t()) :: service() | nil
  def get(name) when is_binary(name), do: Map.get(all(), name)
  def get(_name), do: nil

  @doc """
  Whether a services unit's proposed version may replace its current one on
  a branch: it reads, and no service is declared in two units.
  """
  @spec check(Theseus.Version.t(), String.t()) :: :ok | {:error, [String.t()]}
  def check(%{unit: module, ast: ast}, branch) do
    with {:ok, services} <- from_ast(ast) do
      others =
        for {m, declared} <- units(branch), m != module, name <- Map.keys(declared), do: {name, m}

      case for({name, m} <- others, Map.has_key?(services, name), do: {name, m}) do
        [] ->
          :ok

        twice ->
          {:error,
           Enum.map(twice, fn {name, m} -> "#{name} is already declared in #{inspect(m)}" end)}
      end
    else
      {:error, why} -> {:error, [why]}
    end
  end

  @doc "What changes between two versions of a unit's services, as sentences."
  @spec describe_changes(map(), map()) :: [String.t()]
  def describe_changes(old, new) do
    added =
      for {name, s} <- new,
          not Map.has_key?(old, name),
          do: "adds the service #{name}: #{summary(s)}"

    removed = for {name, _} <- old, not Map.has_key?(new, name), do: "removes the service #{name}"

    changed =
      for {name, s} <- new, o = old[name], o != nil, o != s do
        "changes the service #{name}: now #{summary(s)}"
      end

    Enum.sort(added) ++ Enum.sort(changed) ++ Enum.sort(removed)
  end

  @doc "A service in one sentence, for people."
  @spec summary(service()) :: String.t()
  def summary(s) do
    parts =
      [
        if(s.sign_in, do: "people sign in with it (#{Enum.join(s.sign_in.scopes, ", ")})"),
        if(s.connect,
          do: "an admin connects it, granting #{Enum.join(s.connect.scopes, ", ")}"
        ),
        if(s.urls == [],
          do: "the app sends it no requests",
          else: "the app's requests may go to #{Enum.join(s.urls, ", ")}"
        )
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "; ")
  end
end
