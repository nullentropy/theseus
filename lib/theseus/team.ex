defmodule Theseus.Team do
  @moduledoc """
  The people who work on the app through Theseus, when the review site
  signs them in (team mode, see `Theseus.ReviewSignIn`): their roles, their
  MCP tokens, and the units they own. Without review sign-in Theseus runs
  in local mode, as before: one reviewer link printed at start, and the MCP
  endpoint open to this machine.

  Roles:

    * `engineer`: proposes through MCP with their own tokens, and approves
      changes on branches they created.
    * `reviewer`: also approves on the live branch.
    * `admin`: also adds people, sets roles and owners, and may approve over
      an owner's rule with a reason (`Theseus.Approvals`).

  The first person to sign in becomes an admin. After that, someone signs in
  only when an admin has added them, or when their email domain is listed in
  `THESEUS_REVIEW_DOMAINS` (comma separated), which makes them an engineer.

  An MCP token is made on the review site, one per agent or machine, and
  shown once; the engine keeps its SHA-256. A token may be tied to a branch,
  so the agent works there unless told otherwise.

  Kept with the engine's records (`Theseus.Records`, log `team`).
  """

  use GenServer

  alias Theseus.{Keys, Records}

  @magic "THESEUST"
  @roles ["engineer", "reviewer", "admin"]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The team file's path, when there is no database."
  def path do
    Application.get_env(:theseus, :team_path) ||
      Application.fetch_env!(:theseus, :ledger_path) <> ".team"
  end

  @doc "`:team` when the review site signs people in, `:local` otherwise."
  @spec mode() :: :team | :local
  def mode, do: if(Theseus.ReviewSignIn.configured?(), do: :team, else: :local)

  @doc """
  The person an MCP request acts for, in this process: set by
  `Theseus.MCP` from the request's token, read when a proposal is built.
  """
  @spec acting() :: String.t() | nil
  def acting, do: Process.get({__MODULE__, :acting})

  @doc false
  def act_as(email), do: Process.put({__MODULE__, :acting}, email)

  @doc """
  The person whose decision this process records, for `Theseus.Ledger`
  events that do not name one: set around a decision with `deciding/2`.
  """
  @spec by() :: String.t() | nil
  def by, do: Process.get({__MODULE__, :by})

  @doc false
  def deciding(email, fun) do
    previous = Process.put({__MODULE__, :by}, email)

    try do
      fun.()
    after
      if previous,
        do: Process.put({__MODULE__, :by}, previous),
        else: Process.delete({__MODULE__, :by})
    end
  end

  @doc "The roles, least first."
  def roles, do: @roles

  @doc "Lets someone in after the review site's sign-in: `{:ok, person}` or `{:error, why}`."
  @spec sign_in(map()) :: {:ok, map()} | {:error, String.t()}
  def sign_in(identity), do: call({:sign_in, identity})

  @doc "Everyone, by email address."
  @spec people() :: [map()]
  def people, do: call(:people) || []

  @doc "A person by email address, or nil."
  @spec person(String.t() | nil) :: map() | nil
  def person(nil), do: nil
  def person(email), do: Enum.find(people(), &(&1.email == email))

  @doc "Adds someone with a role."
  def add(email, role, by), do: call({:add, normalize(email), role, by})

  @doc "Gives someone a role."
  def set_role(email, role, by), do: call({:set_role, email, role, by})

  @doc "Removes someone, and their tokens."
  def remove(email, by), do: call({:remove, email, by})

  @doc "Makes an MCP token for a person. Returns `{:ok, token, meta}`; the token is shown once."
  def create_token(email, label, branch \\ nil) do
    branch = if branch in [nil, ""], do: nil, else: branch

    if branch == nil or Theseus.Branches.exists?(branch),
      do: call({:create_token, email, label, branch}),
      else: {:error, "no branch named #{branch}"}
  end

  @doc "A person's tokens, without secrets."
  def tokens(email), do: call({:tokens, email}) || []

  @doc "Revokes a token of `email`'s, or anyone's for an admin (`email` nil)."
  def revoke_token(id, email), do: call({:revoke_token, id, email})

  @doc "The person and token behind an MCP token: `{:ok, person, token}` or `:error`."
  @spec verify_token(String.t()) :: {:ok, map(), map()} | :error
  def verify_token(token), do: call({:verify_token, token}) || :error

  @doc "A unit's owners' email addresses."
  @spec owners(module()) :: [String.t()]
  def owners(unit), do: (call(:owners) || %{}) |> Map.get(inspect(unit), [])

  @doc "Sets a unit's owners."
  def set_owners(unit, emails, by), do: call({:set_owners, inspect(unit), emails, by})

  defp call(message) do
    case Theseus.Leader.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, message)
    end
  end

  defp normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
  defp normalize(_), do: nil

  # Server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    {log, records} =
      if Application.get_env(:theseus, :team_file, true),
        do: Records.open("team", path(), Keys.state(), @magic, sync: true),
        else: {nil, []}

    state =
      Enum.reduce(records, %{log: log, people: %{}, tokens: %{}, owners: %{}}, fn
        {:person, email, :deleted}, s -> %{s | people: Map.delete(s.people, email)}
        {:person, email, p}, s -> %{s | people: Map.put(s.people, email, p)}
        {:token, id, :deleted}, s -> %{s | tokens: Map.delete(s.tokens, id)}
        {:token, id, t}, s -> %{s | tokens: Map.put(s.tokens, id, t)}
        {:owners, unit, emails}, s -> %{s | owners: Map.put(s.owners, unit, emails)}
      end)

    {:ok, state}
  end

  @impl true
  def handle_call({:sign_in, %{email: email} = identity}, _from, s) when is_binary(email) do
    email = normalize(email)
    existing = s.people[email]

    cond do
      existing != nil ->
        p = %{existing | name: identity[:name] || existing.name}
        {:reply, {:ok, p}, put_person(s, p)}

      s.people == %{} ->
        p = person_map(email, identity[:name], "admin", nil)
        {:reply, {:ok, p}, put_person(s, p)}

      domain_allowed?(email) ->
        p = person_map(email, identity[:name], "engineer", nil)
        {:reply, {:ok, p}, put_person(s, p)}

      true ->
        {:reply, {:error, "#{email} is not on this team. Ask an admin to add you."}, s}
    end
  end

  def handle_call({:sign_in, _identity}, _from, s),
    do: {:reply, {:error, "the sign-in gave no email address"}, s}

  def handle_call(:people, _from, s),
    do: {:reply, s.people |> Map.values() |> Enum.sort_by(& &1.email), s}

  def handle_call({:add, email, role, by}, _from, s) do
    cond do
      email == nil or not String.contains?(email, "@") ->
        {:reply, {:error, "give an email address"}, s}

      role not in @roles ->
        {:reply, {:error, "the role is one of #{Enum.join(@roles, ", ")}"}, s}

      Map.has_key?(s.people, email) ->
        {:reply, {:error, "#{email} is already on the team"}, s}

      true ->
        {:reply, :ok, put_person(s, person_map(email, nil, role, by))}
    end
  end

  def handle_call({:set_role, email, role, by}, _from, s) do
    admins = for {_e, %{role: "admin"}} <- s.people, do: 1

    cond do
      role not in @roles ->
        {:reply, {:error, "the role is one of #{Enum.join(@roles, ", ")}"}, s}

      s.people[email] == nil ->
        {:reply, {:error, "#{email} is not on the team"}, s}

      s.people[email].role == "admin" and role != "admin" and length(admins) == 1 ->
        {:reply, {:error, "the last admin stays an admin"}, s}

      true ->
        {:reply, :ok, put_person(s, %{s.people[email] | role: role, changed_by: by})}
    end
  end

  def handle_call({:remove, email, _by}, _from, s) do
    admins = for {_e, %{role: "admin"}} <- s.people, do: 1

    cond do
      s.people[email] == nil ->
        {:reply, {:error, "#{email} is not on the team"}, s}

      s.people[email].role == "admin" and length(admins) == 1 ->
        {:reply, {:error, "the last admin cannot be removed"}, s}

      true ->
        append(s, {:person, email, :deleted})
        s = %{s | people: Map.delete(s.people, email)}

        s =
          Enum.reduce(s.tokens, s, fn
            {id, %{email: ^email}}, s -> drop_token(s, id)
            _, s -> s
          end)

        {:reply, :ok, s}
    end
  end

  def handle_call({:create_token, email, label, branch}, _from, s) do
    if Map.has_key?(s.people, email) do
      token = "tmc_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      id = "tok_" <> Base.encode32(:crypto.strong_rand_bytes(6), case: :lower, padding: false)

      label =
        if is_binary(label) and String.trim(label) != "",
          do: String.slice(String.trim(label), 0, 60),
          else: "an agent"

      meta = %{
        id: id,
        email: email,
        label: label,
        branch: branch,
        hash: :crypto.hash(:sha256, token),
        created_at: DateTime.utc_now(),
        last_used: nil
      }

      append(s, {:token, id, meta})
      {:reply, {:ok, token, Map.delete(meta, :hash)}, %{s | tokens: Map.put(s.tokens, id, meta)}}
    else
      {:reply, {:error, "#{email} is not on the team"}, s}
    end
  end

  def handle_call({:tokens, email}, _from, s) do
    list =
      for {_id, t} <- s.tokens, email == nil or t.email == email do
        Map.delete(t, :hash)
      end

    {:reply, Enum.sort_by(list, & &1.created_at, {:desc, DateTime}), s}
  end

  def handle_call({:revoke_token, id, email}, _from, s) do
    case s.tokens[id] do
      %{email: owner} when email == nil or owner == email -> {:reply, :ok, drop_token(s, id)}
      _ -> {:reply, {:error, "no such token"}, s}
    end
  end

  def handle_call({:verify_token, token}, _from, s) when is_binary(token) do
    h = :crypto.hash(:sha256, token)

    with {id, t} <- Enum.find(s.tokens, fn {_id, t} -> t.hash == h end),
         %{} = person <- s.people[t.email] do
      t = %{t | last_used: DateTime.utc_now()}
      {:reply, {:ok, person, Map.delete(t, :hash)}, %{s | tokens: Map.put(s.tokens, id, t)}}
    else
      _ -> {:reply, :error, s}
    end
  end

  def handle_call({:verify_token, _token}, _from, s), do: {:reply, :error, s}

  def handle_call(:owners, _from, s), do: {:reply, s.owners, s}

  def handle_call({:set_owners, unit, emails, _by}, _from, s) do
    emails = emails |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    unknown = Enum.reject(emails, &Map.has_key?(s.people, &1))

    if unknown == [] do
      append(s, {:owners, unit, emails})
      {:reply, :ok, %{s | owners: Map.put(s.owners, unit, emails)}}
    else
      {:reply, {:error, "not on the team: #{Enum.join(unknown, ", ")}"}, s}
    end
  end

  defp person_map(email, name, role, by) do
    %{
      email: email,
      name: name,
      role: role,
      added_at: DateTime.utc_now(),
      added_by: by,
      changed_by: nil
    }
  end

  defp put_person(s, p) do
    append(s, {:person, p.email, p})
    %{s | people: Map.put(s.people, p.email, p)}
  end

  defp drop_token(s, id) do
    append(s, {:token, id, :deleted})
    %{s | tokens: Map.delete(s.tokens, id)}
  end

  defp append(%{log: nil}, _record), do: :ok
  defp append(%{log: log}, record), do: Records.append(log, record)

  defp domain_allowed?(email) do
    domains =
      (System.get_env("THESEUS_REVIEW_DOMAINS") ||
         Keyword.get(config(), :domains, []) |> Enum.join(","))
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    case String.split(email, "@") do
      [_, domain] -> domain in domains
      _ -> false
    end
  end

  defp config, do: Application.get_env(:theseus, :review_sign_in, [])
end
