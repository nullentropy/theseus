defmodule Mix.Tasks.Theseus.FakeGoogle do
  @shortdoc "Runs a fake Google for local demos of sign-in and Google Workspace"

  @moduledoc """
  Runs a fake Google on 127.0.0.1 for trying sign-in and the Google
  Workspace connection without a Google account:

      mix theseus.fake_google            # port 4999
      mix theseus.fake_google --port 5999

  Then start the app with `THESEUS_FAKE_GOOGLE=http://127.0.0.1:4999` (dev
  only, see `config/dev.exs`), which sends the app's requests to Google's
  addresses here. It answers at Google's own paths. The fake agrees to everything at once: sign-in
  is as `ada@example.com`, or as the `login_hint` the engine sends, and the
  Workspace directory of any domain has the same seven made-up people. It
  changes as it is synced, so joining and leaving show: from the second
  sync of a domain Hana Kim has joined, and from the third Bob Ross is
  suspended. Its groups follow the organizational units (engineering@,
  design@, sales@) plus everyone@.
  Never use it outside this machine.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [port: :integer])
    port = Keyword.get(opts, :port, 4999)
    Application.ensure_all_started(:bandit)
    {Bandit, opts} = Theseus.App.listener(__MODULE__.Plug, {127, 0, 0, 1}, port)
    {:ok, _} = Bandit.start_link(opts)

    Mix.shell().info(
      "Fake Google on http://127.0.0.1:#{port}. Start the app with THESEUS_FAKE_GOOGLE=http://127.0.0.1:#{port}"
    )

    Process.sleep(:infinity)
  end

  defmodule Plug do
    @moduledoc false
    use Elixir.Plug.Router

    plug Elixir.Plug.Parsers, parsers: [:urlencoded]
    plug :match
    plug :dispatch

    @directory "https://www.googleapis.com/auth/admin.directory.user.readonly"

    # Google's authorization address, which config/dev.exs rewrites to here.
    get "/o/oauth2/v2/auth" do
      authorize(conn)
    end

    get "/authorize" do
      authorize(conn)
    end

    # Discovery, for a review site that signs people in with Google
    # (THESEUS_REVIEW_ISSUER=https://accounts.google.com).
    get "/.well-known/openid-configuration" do
      json(conn, 200, %{
        issuer: "https://accounts.google.com",
        authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        token_endpoint: "https://oauth2.googleapis.com/token",
        revocation_endpoint: "https://oauth2.googleapis.com/revoke"
      })
    end

    post "/token" do
      form = conn.body_params

      case form["grant_type"] do
        "refresh_token" ->
          case :persistent_term.get({__MODULE__, :refresh, form["refresh_token"]}, nil) do
            nil ->
              json(conn, 400, %{error: "invalid_grant"})

            domain ->
              json(conn, 200, %{access_token: "at:#{domain}:#{token()}", expires_in: 3599})
          end

        _ ->
          case :persistent_term.get({__MODULE__, :code, form["code"]}, nil) do
            nil -> json(conn, 400, %{error: "invalid_grant"})
            q -> json(conn, 200, tokens(q))
          end
      end
    end

    post "/revoke" do
      json(conn, 200, %{})
    end

    get "/admin/directory/v1/users" do
      with ["Bearer at:" <> rest] <- get_req_header(conn, "authorization"),
           [domain, _] <- String.split(rest, ":") do
        start = String.to_integer(conn.query_params["pageToken"] || "0")
        # A sync starts at the first page.
        if start == 0, do: :persistent_term.put({__MODULE__, :syncs, domain}, syncs(domain) + 1)
        users = users(domain, syncs(domain))
        body = %{users: Enum.slice(users, start, 3)}

        body =
          if start + 3 < length(users),
            do: Map.put(body, :nextPageToken, "#{start + 3}"),
            else: body

        json(conn, 200, body)
      else
        _ -> json(conn, 401, %{error: %{message: "Invalid Credentials"}})
      end
    end

    # Groups follow the organizational units, plus everyone@.
    get "/admin/directory/v1/groups" do
      with {:ok, domain} <- domain(conn) do
        groups =
          for {key, name} <- [
                {"everyone", "Everyone"},
                {"engineering", "Engineering"},
                {"design", "Design"},
                {"sales", "Sales"}
              ] do
            %{
              id: "group-" <> key,
              email: "#{key}@#{domain}",
              name: name,
              description: "#{name} at #{domain}"
            }
          end

        json(conn, 200, %{groups: groups})
      else
        _ -> json(conn, 401, %{error: %{message: "Invalid Credentials"}})
      end
    end

    get "/admin/directory/v1/groups/:key/members" do
      with {:ok, domain} <- domain(conn) do
        [local | _] = String.split(URI.decode_www_form(key), "@")
        unit = "/" <> String.capitalize(local)

        members =
          for u <- users(domain, syncs(domain)), local == "everyone" or u[:orgUnitPath] == unit do
            role = if u[:isAdmin], do: "OWNER", else: "MEMBER"
            %{email: u.primaryEmail, role: role, type: "USER", status: "ACTIVE"}
          end

        json(conn, 200, %{members: members})
      else
        _ -> json(conn, 401, %{error: %{message: "Invalid Credentials"}})
      end
    end

    match _ do
      json(conn, 404, %{error: "not found"})
    end

    defp authorize(conn) do
      q = conn.query_params
      code = token()
      :persistent_term.put({__MODULE__, :code, code}, q)

      conn
      |> put_resp_header(
        "location",
        q["redirect_uri"] <> "?" <> URI.encode_query(code: code, state: q["state"])
      )
      |> send_resp(302, "")
    end

    defp domain(conn) do
      with ["Bearer at:" <> rest] <- get_req_header(conn, "authorization"),
           [domain, _] <- String.split(rest, ":"),
           do: {:ok, domain}
    end

    defp tokens(q) do
      email = q["login_hint"] || "ada@example.com"
      [local, domain] = String.split(email, "@")

      claims =
        %{
          iss: "https://accounts.google.com",
          aud: q["client_id"],
          sub: "sub-" <> local,
          email: email,
          email_verified: true,
          name: String.capitalize(local) <> " Example",
          given_name: String.capitalize(local),
          family_name: "Example",
          nonce: q["nonce"],
          exp: System.os_time(:second) + 3600
        }
        |> then(&if(domain == "gmail.com", do: &1, else: Map.put(&1, :hd, domain)))

      body = %{
        id_token: "e30." <> Base.url_encode64(JSON.encode!(claims), padding: false) <> ".c2ln",
        access_token: "at:#{domain}:#{token()}",
        expires_in: 3599,
        scope: q["scope"]
      }

      if String.contains?(q["scope"] || "", @directory) do
        refresh = token()
        :persistent_term.put({__MODULE__, :refresh, refresh}, domain)
        Map.put(body, :refresh_token, refresh)
      else
        body
      end
    end

    defp syncs(domain), do: :persistent_term.get({__MODULE__, :syncs, domain}, 0)

    defp users(domain, syncs) do
      joiner =
        if syncs >= 2, do: [{"hana", "Hana", "Kim", %{orgUnitPath: "/Engineering"}}], else: []

      bob =
        if syncs >= 3,
          do: %{orgUnitPath: "/Design", suspended: true},
          else: %{orgUnitPath: "/Design"}

      for {local, given, family, extra} <-
            [
              {"ada", "Ada", "Lovelace", %{isAdmin: true, orgUnitPath: "/Engineering"}},
              {"bob", "Bob", "Ross", bob},
              {"carol", "Carol", "Shaw", %{suspended: true, orgUnitPath: "/Engineering"}},
              {"dan", "Dan", "Abramov", %{isEnrolledIn2Sv: false, orgUnitPath: "/Engineering"}},
              {"erin", "Erin", "Catto",
               %{lastLoginTime: "1970-01-01T00:00:00.000Z", orgUnitPath: "/Sales"}},
              {"frank", "Frank", "Herbert", %{isAdmin: true}},
              {"grace", "Grace", "Hopper", %{archived: true, orgUnitPath: "/Engineering"}}
            ] ++ joiner do
        Map.merge(
          %{
            id: "id-" <> local,
            primaryEmail: "#{local}@#{domain}",
            name: %{fullName: "#{given} #{family}", givenName: given, familyName: family},
            suspended: false,
            isAdmin: false,
            orgUnitPath: "/",
            isEnrolledIn2Sv: true,
            creationTime: "2024-03-01T09:00:00.000Z",
            lastLoginTime: "2026-10-12T16:20:00.000Z"
          },
          extra
        )
      end
    end

    defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, JSON.encode!(body))
    end
  end
end
