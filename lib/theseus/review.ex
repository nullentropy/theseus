defmodule Theseus.Review do
  @moduledoc """
  The review page and dashboard: where a person approves or rejects changes,
  reads units' specs, versions and history, follows crashes, and rolls back.
  It shows behaviour and evidence, never source code.

  Pages: `/` (what needs a person, units, crashes, recent history),
  `/history` (the whole ledger, filterable by unit), `/branches` and
  `/branches/:name`, `/changes/:id` and `/units/:name`. Making a branch
  live and proposing merges need the reviewer token too.

  In local mode, approve, reject and rollback need the reviewer token,
  which is set as a cookie by the one-time link printed when the app
  starts. In team mode (`Theseus.Team`) people sign in at `/sign-in`, the
  site shows nothing until they do, and `Theseus.Approvals` decides who may
  approve what. `/team` lists the people and `/tokens` makes MCP tokens.
  """

  use Plug.Router

  alias Theseus.{
    Approvals,
    Branches,
    Change,
    Changes,
    Describe,
    Ledger,
    Registry,
    Spec,
    Team,
    Version
  }

  @cookie "theseus_reviewer"

  plug Plug.Parsers, parsers: [:urlencoded]
  plug :fetch_cookies
  plug :fetch_query_params
  plug :secret

  # In team mode people sign in, and the session says who they are.
  plug :session
  plug :fetch_session
  plug :signed_in
  plug :match
  plug :dispatch

  @session [
    store: :cookie,
    key: "_theseus_review",
    signing_salt: "theseus review",
    encryption_salt: "theseus review session",
    same_site: "Lax",
    http_only: true
  ]

  # The session cookie is sent only over TLS when the site is on https.
  @doc false
  def session(conn, _opts) do
    secure = String.starts_with?(Theseus.ReviewSignIn.url(), "https://")
    Plug.Session.call(conn, Plug.Session.init([{:secure, secure} | @session]))
  end

  @doc false
  def secret(conn, _opts),
    do: %{conn | secret_key_base: Base.encode16(Theseus.Keys.session(), case: :lower)}

  # In team mode the site may be reachable from anywhere, so it shows
  # nothing until someone signs in.
  @doc false
  def signed_in(conn, _opts) do
    open? = conn.path_info in [["sign-in"], ["sign-in", "callback"], ["sign-out"]]

    if Team.mode() == :team and not open? and Team.person(get_session(conn, "person")) == nil do
      conn |> redirect("/sign-in") |> halt()
    else
      conn
    end
  end

  @doc "Creates the reviewer token for this boot."
  def new_token do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :persistent_term.put({__MODULE__, :token}, token)
    token
  end

  def token, do: :persistent_term.get({__MODULE__, :token})

  get "/" do
    case conn.query_params do
      %{"token" => given} when is_binary(given) ->
        if Plug.Crypto.secure_compare(given, token()) do
          conn
          |> put_resp_cookie(@cookie, token(), http_only: true, same_site: "Strict")
          |> redirect("/")
        else
          page(
            conn,
            403,
            "Not signed in",
            "<h2>Not signed in</h2><p class=empty>That reviewer link is not valid for this run of the app.</p>"
          )
        end

      _ ->
        page(conn, 200, "Theseus", index(reviewer?(conn)))
    end
  end

  get "/history" do
    params = conn.query_params

    unit =
      case params["unit"] && unit(params["unit"]) do
        {:ok, unit} -> unit
        _ -> nil
      end

    before =
      case Integer.parse(params["before"] || "") do
        {seq, ""} -> seq
        _ -> nil
      end

    page(conn, 200, "History", history_page(unit, before))
  end

  get "/changes/:id" do
    case Changes.get(id) do
      {:ok, change, report} ->
        d = Describe.change(change, report)
        refresh = if change.status == :shadowing, do: 3, else: nil
        page(conn, 200, change.id, change_page(d, decision(conn, id)), refresh: refresh)

      :error ->
        page(conn, 404, "Not found", "<p>No such change.</p>")
    end
  end

  get "/groups/:id" do
    case Changes.group(id) do
      [] ->
        page(conn, 404, "Not found", "<p>No such group.</p>")

      members ->
        ds = for {c, r} <- members, do: Describe.change(c, r)
        refresh = if Enum.any?(ds, &(&1.status == "shadowing")), do: 3, else: nil
        decide = decision(conn, hd(ds).id)
        page(conn, 200, id, group_page(id, ds, decide, reviewer?(conn)), refresh: refresh)
    end
  end

  post "/changes/:id/approve" do
    with_person(conn, fn person ->
      override = String.trim(conn.body_params["override"] || "")

      approve = fn override ->
        case Changes.approve(id, actor: :human, by: person.email, override: override) do
          {:ok, _} -> redirect(conn, "/changes/#{id}")
          {:error, reason} -> notice(conn, 409, "Not approved", Describe.text(reason))
        end
      end

      case Approvals.check(approval_set(id), person) do
        :ok ->
          approve.(nil)

        {:override, reasons} when override != "" ->
          if person.role == "admin",
            do: approve.(override),
            else: notice(conn, 403, "Not approved", Enum.join(reasons, "; "))

        {:override, reasons} ->
          override_page(conn, id, reasons, person)

        {:error, why} ->
          notice(conn, 403, "Not approved", why)
      end
    end)
  end

  post "/changes/:id/reject" do
    reason = String.trim(conn.body_params["reason"] || "")
    reason = if reason == "", do: "rejected on the review page", else: reason

    with_person(conn, fn person ->
      if Approvals.may_reject?(approval_set(id), person) do
        case Changes.reject(id, reason, actor: :human, by: person.email) do
          {:ok, _} -> redirect(conn, "/changes/#{id}")
          {:error, why} -> notice(conn, 409, "Not rejected", Describe.text(why))
        end
      else
        notice(
          conn,
          403,
          "Not rejected",
          "a reviewer, an admin or the person who proposed it rejects a change"
        )
      end
    end)
  end

  # Signing in to the review site, in team mode (Theseus.ReviewSignIn).
  get "/sign-in" do
    with true <- Team.mode() == :team,
         {:ok, service} <- Theseus.ReviewSignIn.service() do
      state = token(24)
      nonce = token(24)
      verifier = token(48)

      flow = %{
        "state" => state,
        "nonce" => nonce,
        "verifier" => verifier,
        "at" => System.os_time(:second)
      }

      url =
        Theseus.OAuth.authorize_url(service, :sign_in,
          state: state,
          nonce: nonce,
          challenge: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
        )

      conn |> put_session("flow", flow) |> put_resp_header("location", url) |> send_resp(302, "")
    else
      false -> notice(conn, 404, "No sign-in", "This review site uses its reviewer link.")
      {:error, why} -> notice(conn, 503, "Sign-in is not available", why)
    end
  end

  get "/sign-in/callback" do
    flow = get_session(conn, "flow")
    conn = delete_session(conn, "flow")
    q = conn.query_params

    with true <- is_map(flow) and System.os_time(:second) - flow["at"] < 600,
         true <- is_binary(q["state"]) and Plug.Crypto.secure_compare(q["state"], flow["state"]),
         {:ok, service} <- Theseus.ReviewSignIn.service(),
         {:ok, claims, _tokens} <-
           Theseus.OAuth.exchange(service, q["code"] || "", flow["verifier"]),
         {:ok, identity} <-
           Theseus.OAuth.identity(service, claims, flow["nonce"], DateTime.utc_now()),
         {:ok, person} <- Team.sign_in(identity) do
      conn
      |> configure_session(renew: true)
      |> put_session("person", person.email)
      |> redirect("/")
    else
      {:error, why} ->
        notice(conn, 401, "Not signed in", why)

      _ ->
        notice(conn, 400, "Not signed in", "This sign-in expired or does not match. Try again.")
    end
  end

  post "/sign-out" do
    conn |> configure_session(drop: true) |> redirect("/")
  end

  get "/team" do
    page(conn, 200, "Team", team_page(viewer(conn)))
  end

  post "/team/people" do
    with_admin(conn, fn admin ->
      b = conn.body_params

      result =
        case b["action"] do
          "add" -> Team.add(b["email"], b["role"], admin.email)
          "role" -> Team.set_role(b["email"], b["role"], admin.email)
          "remove" -> Team.remove(b["email"], admin.email)
          _ -> {:error, "unknown action"}
        end

      case result do
        :ok -> redirect(conn, "/team")
        {:error, why} -> notice(conn, 422, "Not changed", why)
      end
    end)
  end

  get "/tokens" do
    with_person(conn, fn person -> page(conn, 200, "MCP tokens", tokens_page(person, nil)) end)
  end

  post "/tokens" do
    with_person(conn, fn person ->
      case Team.create_token(person.email, conn.body_params["label"], conn.body_params["branch"]) do
        {:ok, token, _meta} -> page(conn, 200, "MCP tokens", tokens_page(person, token))
        {:error, why} -> notice(conn, 422, "No token", why)
      end
    end)
  end

  post "/tokens/:id/revoke" do
    with_person(conn, fn person ->
      owner = if person.role == "admin", do: nil, else: person.email

      case Team.revoke_token(id, owner) do
        :ok ->
          redirect(conn, if(conn.body_params["back"] == "team", do: "/team", else: "/tokens"))

        {:error, why} ->
          notice(conn, 404, "Not revoked", why)
      end
    end)
  end

  post "/units/:name/owners" do
    with_admin(conn, fn admin ->
      emails = String.split(conn.body_params["owners"] || "", ~r/[\s,]+/, trim: true)

      with {:ok, unit} <- unit(name),
           :ok <- Team.set_owners(unit, emails, admin.email) do
        redirect(conn, "/units/#{name}")
      else
        {:error, why} -> notice(conn, 422, "Owners not changed", why)
        :error -> notice(conn, 404, "Not found", "No such unit.")
      end
    end)
  end

  post "/crashes/:id/resolve" do
    with_reviewer(conn, fn ->
      case Theseus.Trigger.resolve(id) do
        :ok -> redirect(conn, "/")
        {:error, :busy} -> page(conn, 409, "Not now", "<p>A fix for this crash is under way.</p>")
        {:error, _} -> page(conn, 404, "Not found", "<p>No such crash.</p>")
      end
    end)
  end

  post "/crashes/:id/retry" do
    with_reviewer(conn, fn ->
      case Theseus.Trigger.retry(id) do
        :ok -> redirect(conn, "/")
        {:error, _} -> page(conn, 404, "Not found", "<p>No such crash.</p>")
      end
    end)
  end

  get "/routes" do
    page(conn, 200, "Routes", routes_page())
  end

  get "/connections" do
    page(conn, 200, "Connections", connections_page(reviewer?(conn)))
  end

  post "/groups/:id/undo" do
    with_reviewer(conn, fn ->
      case Changes.undo_group(id) do
        :ok ->
          redirect(conn, "/groups/#{id}")

        {:error, why} ->
          page(conn, 409, "Not undone", "<h2>Not undone</h2><p class=empty>#{h(why)}</p>")
      end
    end)
  end

  post "/grants/:id/revoke" do
    with_reviewer(conn, fn ->
      :ok = Theseus.Clients.revoke_grant(id)
      redirect(conn, "/connections")
    end)
  end

  post "/outbox/:id/resend" do
    with_reviewer(conn, fn ->
      case Theseus.Outbox.resend(id) do
        :ok -> redirect(conn, "/outbox")
        {:error, reason} -> page(conn, 409, "Not sent", "<p>#{h(Describe.text(reason))}</p>")
      end
    end)
  end

  # Messages hold personal data, so only a reviewer sees them.
  get "/outbox" do
    if reviewer?(conn),
      do: page(conn, 200, "Outbox", outbox_page()),
      else:
        page(
          conn,
          403,
          "Outbox",
          "<h2>Outbox</h2><p class=empty>Open the reviewer link printed when the app started to see the outbox.</p>"
        )
  end

  get "/branches" do
    page(conn, 200, "Branches", branches_page(viewer(conn) != nil))
  end

  post "/branches" do
    with_person(conn, fn _person ->
      name = String.trim(conn.body_params["name"] || "")
      from = conn.body_params["from"] || Branches.main()

      case Branches.create(name, from,
             actor: :human,
             by: (viewer(conn) || %{})[:email],
             description: conn.body_params["description"]
           ) do
        :ok -> redirect(conn, "/branches/#{name}")
        {:error, reason} -> page(conn, 409, "Not created", "<p>#{h(reason)}</p>")
      end
    end)
  end

  get "/branches/:name" do
    if Branches.exists?(name),
      do: page(conn, 200, name, branch_page(name, viewer(conn))),
      else: page(conn, 404, "Not found", "<p>No such branch.</p>")
  end

  post "/branches/:name/describe" do
    with_branch_person(conn, name, fn ->
      by = (viewer(conn) || %{})[:email]

      case Branches.describe(name, conn.body_params["description"], by: by) do
        :ok -> redirect(conn, "/branches/#{name}")
        {:error, why} -> notice(conn, 422, "Not changed", why)
      end
    end)
  end

  post "/branches/:name/close" do
    with_branch_person(conn, name, fn ->
      by = (viewer(conn) || %{})[:email]
      action = if conn.body_params["reopen"] == "true", do: :reopen, else: :close

      case apply(Branches, action, [name, [by: by]]) do
        :ok -> redirect(conn, "/branches/#{name}")
        {:error, why} -> notice(conn, 409, "Not changed", why)
      end
    end)
  end

  post "/branches/:name/live" do
    with_reviewer(conn, fn ->
      case Theseus.switch(name) do
        :ok -> redirect(conn, "/branches")
        {:error, reason} -> page(conn, 409, "Not switched", "<p>#{h(Describe.text(reason))}</p>")
      end
    end)
  end

  post "/branches/:name/merge" do
    into = conn.body_params["into"] || ""

    with_person(conn, fn person ->
      proposer = %{kind: :review, client: nil, person: person.email}

      case Branches.merge(name, into, proposer: proposer) do
        {:ok, _merge} -> redirect(conn, "/branches/#{name}")
        {:error, reason} -> page(conn, 409, "Not merged", "<p>#{h(reason)}</p>")
      end
    end)
  end

  get "/branches/:name/preview/open" do
    with_person(conn, fn person ->
      running? = Enum.any?(Theseus.Previews.list(), &(&1.branch == name))

      if (running? and Theseus.PreviewProxy.domain()) && person[:email],
        do: redirect(conn, Theseus.PreviewProxy.open_url(name, person.email)),
        else: redirect(conn, "/branches/#{name}")
    end)
  end

  post "/branches/:name/preview" do
    with_branch_person(conn, name, fn ->
      result =
        if conn.body_params["stop"] == "true",
          do: Theseus.Previews.stop(name),
          else: Theseus.Previews.start(name, keep: conn.body_params["keep"] == "true")

      case result do
        {:error, reason} -> page(conn, 409, "No preview", "<p>#{h(Describe.text(reason))}</p>")
        _ -> redirect(conn, "/branches/#{name}")
      end
    end)
  end

  get "/units/:name" do
    case unit(name) do
      {:ok, unit} ->
        admin? = match?(%{role: "admin"}, viewer(conn))
        page(conn, 200, inspect(unit), unit_page(unit, reviewer?(conn), admin?))

      :error ->
        page(conn, 404, "Not found", "<p>No such unit.</p>")
    end
  end

  post "/units/:name/rollback" do
    with_reviewer(conn, fn ->
      with {:ok, unit} <- unit(name),
           module =
             if(conn.body_params["what"] == "spec", do: Registry.fetch!(unit).spec, else: unit),
           to = rollback_target(conn.body_params["to"]),
           {:ok, _} <- Theseus.rollback(module, to) do
        redirect(conn, "/units/#{name}")
      else
        {:error, reason} ->
          page(conn, 409, "Not rolled back", "<p>#{h(Describe.text(reason))}</p>")

        :error ->
          page(conn, 404, "Not found", "<p>No such unit.</p>")
      end
    end)
  end

  match _ do
    page(conn, 404, "Not found", "<p>Not found.</p>")
  end

  ## Pages

  defp rollback_target(to) when is_binary(to) and byte_size(to) >= 6, do: to
  defp rollback_target(_to), do: :previous

  defp index(reviewer?) do
    held = Changes.list(status: :held)
    waiting = held |> collapse_groups() |> length()

    # A group goes with the spec changes if any of its changes touches a spec.
    spec_groups =
      for {c, _} <- held,
          c.group != nil,
          Change.spec_candidate(c),
          into: MapSet.new(),
          do: c.group

    {spec_held, held} =
      Enum.split_with(held, fn {c, _} ->
        Change.spec_candidate(c) != nil or MapSet.member?(spec_groups, c.group)
      end)

    shadowing = Changes.list(status: :shadowing)

    recent =
      Changes.list(limit: 15) |> Enum.reject(fn {c, _} -> c.status in [:held, :shadowing] end)

    statuses = Theseus.status()
    crashes = Theseus.Trigger.list()
    open_crashes = Enum.count(crashes, &(&1.status != :resolved))
    events = Ledger.recent(15)
    comparing = shadowing |> collapse_groups() |> length()

    kinds =
      statuses
      |> Enum.frequencies_by(& &1.kind)
      |> Enum.sort_by(fn {kind, n} -> {-n, kind} end)
      |> Enum.map_join(", ", fn {kind, n} -> "#{n} #{kind}" end)

    [
      "<h2>Dashboard</h2>",
      "<p class=meta>The app runs branch #{branch_link(Branches.live())}. ",
      "The ledger holds #{case List.last(events) do
        %{seq: seq} -> seq
        nil -> 0
      end} events.</p>",
      "<div class=tiles>",
      tile(
        "#waiting",
        "Waiting for you",
        waiting,
        if(waiting == 0, do: "Nothing to review", else: "Approve or reject"),
        waiting > 0
      ),
      tile("#comparing", "Being compared", comparing, "with live calls", false),
      tile("#units", "Units", length(statuses), kinds, false),
      tile(
        "#crashes",
        "Crashes",
        open_crashes,
        if(open_crashes == 0, do: "None open", else: "Open"),
        false
      ),
      "</div>",
      "<h3 id=waiting>Waiting for you</h3>",
      if(held == [] and spec_held == [],
        do: "<p class=empty>Nothing to review.</p>",
        else: if(held == [], do: "", else: change_table(held))
      ),
      if(spec_held == [],
        do: "",
        else: [
          "<h4>Spec changes</h4>",
          "<p class=muted>These change what the unit is required to do. Read the spec changes on each page.</p>",
          change_table(spec_held)
        ]
      ),
      if(shadowing == [],
        do: "",
        else: [
          "<h3 id=comparing>Being compared with live calls</h3>",
          "<p class=muted>These go to you when the comparison ends.</p>",
          change_table(shadowing)
        ]
      ),
      crash_table(crashes, reviewer?),
      "<h3 id=units>Units</h3>",
      unit_table(statuses),
      "<h3>Recent decisions</h3>",
      if(recent == [], do: "<p class=empty>None yet.</p>", else: change_table(recent)),
      "<h3>Recent history</h3>",
      event_list(Enum.reverse(events), true),
      "<p><a href=\"/history\">The whole history</a></p>"
    ]
  end

  defp tile(href, label, n, sub, hot?) do
    class = if hot?, do: "tile hot", else: "tile"

    "<a class=\"#{class}\" href=\"#{href}\"><div class=label>#{label}</div>" <>
      "<div class=n>#{n}</div><div class=sub>#{h(sub)}</div></a>"
  end

  defp history_page(unit, before) do
    per_page = 200

    events =
      if(unit, do: Ledger.events_for(unit), else: Ledger.events())
      |> Enum.filter(&(before == nil or &1.seq < before))
      |> Enum.take(-per_page)
      |> Enum.reverse()

    older =
      case List.last(events) do
        %{seq: seq} when seq > 1 and length(events) == per_page ->
          query =
            URI.encode_query(
              Enum.reject([unit: unit && inspect(unit), before: seq], &is_nil(elem(&1, 1)))
            )

          "<p><a href=\"/history?#{query}\">Older</a></p>"

        _ ->
          ""
      end

    units =
      for u <- Registry.units() do
        name = inspect(u.module)
        on = if u.module == unit, do: " class=on", else: ""
        "<a href=\"/history?unit=#{name}\"#{on}>#{h(name)}</a>"
      end

    [
      "<h2>History#{if unit, do: " of " <> h(inspect(unit)), else: ""}</h2>",
      "<p class=meta>Every event in the ledger, newest first.</p>",
      "<div class=chips><a href=\"/history\"#{if unit, do: "", else: " class=on"}>All units</a>",
      units,
      "</div>",
      event_list(events, unit == nil),
      older
    ]
  end

  defp event_list([], _show_unit?), do: "<p class=muted>Nothing yet.</p>"

  defp event_list(events, show_unit?) do
    rows =
      for e <- events do
        unit =
          if show_unit? and e.unit,
            do:
              "<td class=nw><a href=\"/units/#{inspect(e.unit)}\">#{h(inspect(e.unit))}</a></td>",
            else: if(show_unit?, do: "<td></td>", else: "")

        "<tr><td class=\"muted nw\">#{time(e.at)}</td>#{unit}<td>#{branch_link(e.branch)}</td><td class=\"muted nw\">#{h(Map.get(e, :by) || e.actor)}</td>" <>
          "<td>#{linkify(Describe.event(e.body))}</td></tr>"
      end

    [
      "<table><tr><th>When</th>",
      if(show_unit?, do: "<th>Unit</th>", else: ""),
      "<th>Branch</th><th>By</th><th>What</th></tr>",
      rows,
      "</table>"
    ]
  end

  defp crash_table(all, show_actions?) do
    {resolved, crashes} = Enum.split_with(all, &(&1.status == :resolved))

    hidden =
      case length(resolved) do
        0 -> ""
        1 -> "<p class=muted>1 crash marked resolved is not shown.</p>"
        n -> "<p class=muted>#{n} crashes marked resolved are not shown.</p>"
      end

    if crashes == [] do
      if resolved == [], do: "", else: ["<h3 id=crashes>Crashes</h3>", hidden]
    else
      rows =
        for c <- crashes do
          retry =
            if show_actions? and c.status == :needs_human,
              do:
                "<form method=post action=\"/crashes/#{c.id}/retry\" class=inline><button>Allow another attempt</button></form>",
              else: ""

          resolve =
            if show_actions? and c.status in [:idle, :needs_human, :fixed],
              do:
                "<form method=post action=\"/crashes/#{c.id}/resolve\" class=inline><button>Mark resolved</button></form>",
              else: ""

          action = retry <> resolve

          change =
            if c.change_id, do: "<a href=\"/changes/#{c.change_id}\">#{c.change_id}</a>", else: ""

          "<tr><td>#{h(Theseus.Signature.describe_short(c.signature))}<div class=muted>#{c.id}</div></td>" <>
            "<td>#{crash_status(c.status)}#{if c.note, do: "<div class=muted>#{h(c.note)}</div>", else: ""}</td>" <>
            "<td>#{c.count}</td><td>#{c.attempts}</td><td>#{change}</td><td>#{action}</td></tr>"
        end

      [
        "<h3 id=crashes>Crashes</h3>",
        if(Theseus.LLM.available?(),
          do: "",
          else:
            "<p class=muted>Crash repair is off: #{h(Theseus.LLM.name())} is not available (#{h(Theseus.LLM.setup())}).</p>"
        ),
        "<table><tr><th>Crash</th><th>Status</th><th>Seen</th><th>Attempts</th><th>Change</th><th></th></tr>",
        rows,
        "</table>",
        hidden
      ]
    end
  end

  defp crash_status(status) do
    {label, class} =
      case status do
        :needs_human -> {"needs a person", "bad"}
        :held -> {"fix waiting for you", "wait"}
        :watching -> {"fixed, being watched", "info"}
        :fixed -> {"fixed", "ok"}
        :collecting -> {"collecting", "info"}
        :proposing -> {"fixing", "info"}
        :idle -> {"seen", "muted"}
        :resolved -> {"resolved", "ok"}
      end

    "<span class=\"badge #{class}\">#{label}</span>"
  end

  defp change_table(changes) do
    rows =
      for entry <- collapse_groups(changes) do
        # A group's row opens the page that shows all its changes at once.
        {d, units, more, link} =
          case entry do
            {:one, c} ->
              d = Describe.summary(c)
              {d, h(inspect(c.unit)), "", "/changes/#{d.id}"}

            {:group, [first | _] = members} ->
              units = Enum.map_join(members, ", ", &h(inspect(&1.unit)))

              {Describe.summary(first), units, " and #{length(members) - 1} more, together",
               "/groups/#{first.group}"}
          end

        branch =
          if d.branch == Branches.main(), do: "", else: "<div class=muted>on #{h(d.branch)}</div>"

        "<tr><td><a href=\"#{link}\" class=title>#{h(d.intent)}</a>" <>
          "<div class=muted><code>#{d.id}</code>#{more}</div></td><td>#{status(d.status)}</td>" <>
          "<td>#{units}#{branch}</td><td class=muted>#{h(d.proposer)}</td></tr>"
      end

    [
      "<table><tr><th>Request</th><th>Status</th><th>Units</th><th>From</th></tr>",
      rows,
      "</table>"
    ]
  end

  # The changes of a group, where they appear together in a list, become
  # one row.
  defp collapse_groups(changes) do
    {rows, _seen} =
      Enum.flat_map_reduce(changes, MapSet.new(), fn {c, _}, seen ->
        cond do
          c.group == nil ->
            {[{:one, c}], seen}

          MapSet.member?(seen, c.group) ->
            {[], seen}

          true ->
            members =
              for({m, _} <- changes, m.group == c.group, do: m) |> Enum.sort_by(& &1.at, DateTime)

            entry = if length(members) == 1, do: {:one, c}, else: {:group, members}
            {[entry], MapSet.put(seen, c.group)}
        end
      end)

    rows
  end

  defp unit_table(statuses) do
    threshold = Theseus.Consolidate.threshold()

    rows =
      for s <- statuses do
        name = inspect(s.unit)

        state = if s.kind == :server, do: ", " <> state_note(s.unit), else: ""
        filled = min(100, div(s.since_rewrite * 100, max(threshold, 1)))
        bar = if s.since_rewrite >= threshold, do: "bar full", else: "bar"

        pending =
          if s.pending > 0,
            do: "<span class=\"badge wait\">#{s.pending} pending</span>",
            else: "<span class=muted>none</span>"

        "<tr><td><a href=\"/units/#{name}\" class=title>#{h(name)}</a><div class=muted>#{s.kind}, #{s.traces} recent calls#{state}</div></td>" <>
          "<td><code>#{s.version}</code><div class=muted>#{s.versions} versions, spec <code>#{s.spec_version}</code></div></td>" <>
          "<td>#{s.since_rewrite} of #{threshold}<span class=\"#{bar}\"><i style=\"width:#{filled}%\"></i></span></td>" <>
          "<td>#{pending}</td><td class=muted>#{short_time(s.last_change)}</td></tr>"
      end

    if rows == [],
      do: "<p class=muted>No units yet.</p>",
      else: [
        "<table><tr><th>Unit</th><th>Version</th><th>Changes since rewrite</th>",
        "<th>Pending</th><th>Last change</th></tr>",
        rows,
        "</table>"
      ]
  end

  defp change_page(d, decide) do
    # When the root endpoint calls this unit, its replay is what people see.
    {root, root_calls} =
      case root_evidence([], d.dependents) do
        {root, calls} when calls != nil and root != d.unit -> {root, calls}
        _ -> {nil, nil}
      end

    unit = if d.creates, do: h(d.unit), else: "<a href=\"/units/#{d.unit}\">#{h(d.unit)}</a>"

    [
      "<div class=eyebrow>#{unit} &middot; <code>#{d.id}</code></div>",
      "<h2>#{h(d.intent)}</h2>",
      "<p class=meta>#{status(d.status)} &middot; #{what_it_does(d, "this unit")} &middot; ",
      "on branch <a href=\"/branches/#{d.branch}\">#{h(d.branch)}</a>",
      if(d.branch == Branches.live(),
        do: " (live)",
        else: " (not live: approving records it there, nothing runs)"
      ),
      " &middot; from #{h(d.proposer)} &middot; #{when_text(d.at)}</p>",
      group_section(d.group),
      "<p>",
      if(d.behaviour_change,
        do: "The proposer says this change is meant to change behaviour.",
        else: "The proposer says this change keeps behaviour the same."
      ),
      "</p>",
      if(d.compacted,
        do:
          "<p class=muted>The ledger was compacted after this change was decided. Its code and " <>
            "detailed evidence were removed; each check keeps a short summary. " <>
            "The archived ledger file has the rest.</p>",
        else: ""
      ),
      if(d.services_changes != [],
        do: [
          "<h3>Outside services</h3><ul>",
          Enum.map(d.services_changes, &"<li>#{h(&1)}</li>"),
          "</ul>"
        ],
        else: ""
      ),
      if(d.schema_changes != [],
        do: [
          "<h3>Data</h3><ul>",
          Enum.map(d.schema_changes, &"<li>#{h(&1)}</li>"),
          "</ul>"
        ],
        else: ""
      ),
      progress(d.shadow_progress),
      crash_section(d.crash),
      if(d.held_because, do: "<p>Held for you because #{h(d.held_because)}.</p>", else: ""),
      case d.combined do
        %{replaces: replaced, onto: onto} ->
          "<p class=note>The engine made this change: #{Enum.map_join(replaced, ", ", &change_link/1)} " <>
            "changed other functions of the same units as #{change_link(onto)}, which was approved first, so their edits are combined here.</p>"

        nil ->
          ""
      end,
      if(d.rationale != "",
        do: "<h3>The proposer's explanation</h3><blockquote>#{h(d.rationale)}</blockquote>",
        else: ""
      ),
      actions(d, decide),
      "<h3>Checks</h3><ul class=stages>",
      for s <- d.stages do
        "<li>#{status(s.result)}<div><b>#{h(s.name)}</b>" <>
          Enum.map_join(s.lines, "", &"<div class=muted>#{h(&1)}</div>") <> "</div></li>"
      end,
      "</ul>",
      what_people_see(root, root_calls),
      differences(
        "Effect on recorded calls",
        "Re-ran the recorded calls on the unit's current version and on the proposed one.",
        d.behaviour
      ),
      differences(
        "Effect on live calls",
        "Ran the proposed unit beside the live one while real calls came in.",
        d.shadow
      ),
      for dep <- d.dependents do
        [
          if(dep.failed != [],
            do:
              "<h3>#{h(dep.unit)} would break</h3><p>It calls a changed unit, and its spec fails with the proposed versions:</p><ul>" <>
                Enum.map_join(dep.failed, "", &"<li>#{h(&1)}</li>") <> "</ul>",
            else: ""
          ),
          if(dep.unit != root,
            do:
              differences(
                "Effect on #{dep.unit}, which calls it",
                "Re-ran #{dep.unit}'s recorded calls with the proposed versions of the units it calls.",
                dep.calls
              ),
            else: ""
          )
        ]
      end,
      spec_changes_section(d.spec_changes),
      if(d.spec_after,
        do: ["<h3>The spec after this change</h3>", spec_section(d.spec_after)],
        else: ""
      )
    ]
  end

  defp what_it_does(%{removes: true}, it), do: "removes #{it} and its spec"
  defp what_it_does(%{creates: true}, it), do: "creates #{it}"
  defp what_it_does(d, _it), do: "changes the #{Enum.join(d.touches, " and ")}"

  defp actions(%{status: "held", id: id} = d, true) do
    {approve, reject} =
      case d.group do
        %{changes: changes} when length(changes) > 1 ->
          {"Approve all #{length(changes)} changes", "Reject all"}

        _ ->
          {"Approve", "Reject"}
      end

    """
    <div class=actions>
    <form method=post action="/changes/#{id}/approve" class=inline><button class=approve>#{approve}</button></form>
    <form method=post action="/changes/#{id}/reject" class=inline>
      <input name=reason placeholder="Reason (optional)"> <button class=reject>#{reject}</button>
    </form>
    </div>
    """
  end

  defp actions(%{status: "shadowing", id: id}, true) do
    """
    <div class=actions>
    <p class=muted>You can approve once the comparison with live calls ends.</p>
    <form method=post action="/changes/#{id}/reject" class=inline>
      <input name=reason placeholder="Reason (optional)"> <button class=reject>Reject</button>
    </form>
    </div>
    """
  end

  defp actions(d, {:override, reasons}) do
    [
      "<p class=note>You cannot approve this yet: #{h(Enum.join(reasons, "; "))}. ",
      "An admin may approve anyway, with a reason.</p>",
      actions(d, true)
    ]
  end

  # The person who proposed it may take it back.
  defp actions(%{status: status, id: id}, :reject) when status in ["held", "shadowing"] do
    """
    <div class=actions>
    <p class=muted>A reviewer or an admin approves this. You proposed it, so you may reject it.</p>
    <form method=post action="/changes/#{id}/reject" class=inline>
      <input name=reason placeholder="Reason (optional)"> <button class=reject>Reject</button>
    </form>
    </div>
    """
  end

  defp actions(%{status: status}, false) when status in ["held", "shadowing"] do
    if Team.mode() == :team,
      do: "<p class=note>A reviewer or an admin approves or rejects this.</p>",
      else:
        "<p class=note>Open the reviewer link printed when the app started to approve or reject.</p>"
  end

  defp actions(_d, _reviewer?), do: ""

  defp group_section(nil), do: ""

  # A change made with others is reviewed with them, on the group's page.
  defp group_section(%{id: group, changes: changes}) do
    n = length(changes)

    [
      "<div class=callout><div><b>One of #{n} changes made together.</b> ",
      "Made together with other changes, which are approved or rejected together, so review them as one.</div>",
      "<a class=button href=\"/groups/#{group}\">Review all #{n} on one page</a></div><ul class=members>",
      for c <- changes do
        if c.this,
          do:
            "<li><b>#{h(c.unit)}</b> <span class=muted>this change</span>#{status(c.status)}</li>",
          else: "<li><a href=\"/changes/#{c.id}\">#{h(c.unit)}</a>#{status(c.status)}</li>"
      end,
      "</ul>"
    ]
  end

  # A group on one page: what each change does, its checks, what people
  # see (the root endpoint's replay), its spec changes, and the effect on
  # recorded calls of each unit and of the units that call them.
  defp group_page(id, [first | _] = ds, decide, reviewer?) do
    statuses = ds |> Enum.map(& &1.status) |> Enum.uniq()
    in_group = MapSet.new(ds, & &1.unit)

    callers =
      ds
      |> Enum.flat_map(& &1.dependents)
      |> Enum.uniq_by(& &1.unit)
      |> Enum.reject(&MapSet.member?(in_group, &1.unit))

    {root, root_calls} = root_evidence(ds, callers)

    [
      "<div class=eyebrow>Group &middot; <code>#{id}</code></div>",
      "<h2>#{h(first.intent)}</h2>",
      "<p class=meta>#{Enum.map_join(statuses, " ", &status/1)} &middot; #{length(ds)} changes made together ",
      "&middot; on branch #{branch_link(first.branch)} &middot; from #{h(first.proposer)}</p>",
      if(first.rationale != "",
        do: "<h3>The proposer's explanation</h3><blockquote>#{h(first.rationale)}</blockquote>",
        else: ""
      ),
      actions(
        Map.put(first, :status, if(statuses == ["held"], do: "held", else: hd(statuses))),
        decide
      ),
      undo_section(id, statuses, length(ds), reviewer?),
      "<table class=group><tr><th>Unit</th><th>Change</th><th>Checks</th></tr>",
      for d <- ds do
        checks =
          d.stages
          |> Enum.reject(&(&1.result in ["skip"]))
          |> Enum.map_join(
            " ",
            &"<span class=\"badge #{badge_class(&1.result)}\" title=\"#{h(&1.result)}\">#{h(&1.name)}</span>"
          )

        what =
          what_it_does(d, "it")

        "<tr><td><a href=\"/changes/#{d.id}\">#{h(d.unit)}</a></td><td>#{what}</td><td>#{checks}</td></tr>"
      end,
      "</table>",
      what_people_see(root, root_calls),
      for d <- ds, d.spec_changes != nil do
        ["<h3>#{h(d.unit)}</h3>", spec_changes_section(d.spec_changes)]
      end,
      if(root_calls && Enum.any?(ds, &(&1.unit != root and &1.behaviour != nil)),
        do: "<h3>Inside the app, unit by unit</h3>",
        else: ""
      ),
      for d <- ds, d.unit != root, d.behaviour != nil, d.behaviour.compared > 0 do
        differences(
          "Effect on #{d.unit}, on its recorded calls",
          "Re-ran #{d.unit}'s recorded calls through the current system and the proposed one.",
          d.behaviour
        )
      end,
      for dep <- callers do
        [
          if(dep.failed != [],
            do:
              "<h3>#{h(dep.unit)} would break</h3><p>It calls a changed unit, and its spec fails with the proposed versions:</p><ul>" <>
                Enum.map_join(dep.failed, "", &"<li>#{h(&1)}</li>") <> "</ul>",
            else: ""
          ),
          if(dep.unit != root,
            do:
              differences(
                "Effect on #{dep.unit}, which calls them",
                "Re-ran #{dep.unit}'s recorded calls with the proposed versions of the units it calls.",
                dep.calls
              ),
            else: ""
          )
        ]
      end
    ]
  end

  # An approved group can be undone in one step, while nothing it touched
  # has changed since.
  defp undo_section(id, statuses, n, reviewer?) do
    cond do
      statuses != ["promoted"] ->
        ""

      Changes.undone?(id) ->
        "<p class=note>This group was undone: its units went back to their versions from before it.</p>"

      reviewer? ->
        """
        <div class=actions>
        <p class=muted>Undoing puts every unit and spec these #{n} changes touched back to its version from before them, removes the units they created and brings back the ones they removed. Nothing is undone if any of them has changed since.</p>
        <form method=post action="/groups/#{id}/undo" class=inline><button class=reject>Undo all #{n} changes</button></form>
        </div>
        """

      true ->
        ""
    end
  end

  # The unit that answers every request, and its replay: from its own
  # change in the group, or from the dependents stage when it only calls
  # changed units.
  defp root_evidence(ds, callers) do
    root = inspect(Theseus.Web.endpoint())

    calls =
      Enum.find_value(ds, &(&1.unit == root && &1.behaviour)) ||
        Enum.find_value(callers, &(&1.unit == root && &1.calls))

    if calls && calls.compared > 0, do: {root, calls}, else: {root, nil}
  end

  defp what_people_see(_root, nil), do: ""

  defp what_people_see(root, b) do
    differences(
      "What people see",
      "#{root} answers every request to the app. Re-ran its recorded requests through the current app and the proposed one.",
      b
    )
  end

  defp crash_section(nil), do: ""

  defp crash_section(c) do
    [
      "<p>Proposed by crash repair after a crash: <b>#{h(c.what)}</b> ",
      "(signature #{c.signature}, attempt #{c.attempt}#{if c.round == 2, do: ", repair round", else: ""}).</p>",
      "<p class=muted>The crash, as recorded. This is data from outside the system.</p>",
      "<pre>#{h(c.untrusted_report)}</pre>"
    ]
  end

  defp progress(nil), do: ""

  defp progress(p) do
    "<p>#{status("shadowing")} Compared #{p.compared} of up to #{p.calls} live calls so far, " <>
      "#{p.differ} behaved differently. At most #{p.seconds_left} s left.</p>"
  end

  defp differences(_title, _intro, nil), do: ""

  defp differences(title, intro, b) do
    c = b.counts

    groups =
      for {label, rows, count} <- [
            {"Crashed, now work", b.fixed, c.fixed},
            {"Crashed, and still fail", b.unfixed, c.unfixed},
            {"Give a different result", b.changed, c.changed},
            {"Used to fail, now succeed", b.now_succeed, c.now_succeed},
            {"Used to succeed, now fail", b.now_fail, c.now_fail},
            {"Call a function the proposed version no longer has", Map.get(b, :removed, []),
             Map.get(c, :removed, 0)}
          ],
          rows != [] do
        shown = if length(rows) < count, do: " (showing #{length(rows)})", else: ""

        # A removed function's calls are not run: the row shows what was
        # recorded, perhaps on another version.
        first = if label =~ "no longer has", do: "Recorded", else: "Before"

        [
          "<h4>#{label}: #{count}#{shown}</h4>",
          "<table class=calls><tr><th>Call</th><th>#{first}</th><th>After</th></tr>",
          for r <- rows do
            "<tr><td>#{h(r.call)}</td><td>#{h(r.before_changed || r.before)}</td>" <>
              "<td>#{h(r.after_changed || r.after)}</td></tr>"
          end,
          "</table>"
        ]
      end

    [
      "<h3>#{title}</h3>",
      "<p>#{intro} #{b.compared} calls compared: #{c.changed} give a different result#{Describe.styling_note(c)}, " <>
        "#{c.now_succeed} now succeed, #{c.now_fail} now fail.</p>",
      if(groups == [], do: "<p class=muted>None of them behave differently.</p>", else: groups),
      if(Enum.any?(b.changed, & &1.before_changed),
        do:
          "<p class=muted>For results with several fields, only the fields that differ are shown.</p>",
        else: ""
      )
    ]
  end

  defp spec_changes_section(nil), do: ""

  defp spec_changes_section(s) do
    items =
      Enum.map(
        s.examples_added,
        &"<li class=add>New example: #{h(&1.name)}: #{h(&1.call)} gives #{h(&1.expect)}</li>"
      ) ++
        Enum.map(s.examples_removed, &"<li class=del>Removed example: #{h(&1.name)}</li>") ++
        Enum.map(s.examples_changed, fn c ->
          now =
            if c.before.call == c.after.call,
              do: "now gives #{h(c.after.expect)}",
              else: "now #{h(c.after.call)} gives #{h(c.after.expect)}"

          "<li class=chg>Changed example: #{h(c.name)}: #{h(c.before.call)} gave #{h(c.before.expect)}, #{now}</li>"
        end) ++
        Enum.map(s.rules_added, &"<li class=add>New rule: #{h(&1)}</li>") ++
        Enum.map(s.rules_removed, &"<li class=del>Removed rule: #{h(&1)}</li>") ++
        Enum.map(s.invariants_added, &"<li class=add>New rule: #{h(&1)}</li>") ++
        Enum.map(s.invariants_removed, &"<li class=del>Removed rule: #{h(&1)}</li>") ++
        Enum.map(
          Map.get(s, :rules_changed, []),
          &"<li class=chg>Same sentence, changed check: #{h(&1)}. Read what it now requires in the examples and in what the live unit does not do yet.</li>"
        ) ++
        if(s.prose, do: ["<li class=chg>New description: #{h(s.prose.after)}</li>"], else: [])

    misses =
      if s.live_unit_misses == [],
        do: "",
        else: [
          "<p>What the live unit does not do yet:</p><ul>",
          Enum.map(s.live_unit_misses, &"<li>#{h(&1)}</li>"),
          "</ul>"
        ]

    ["<h3>Spec changes</h3><ul class=diff>", items, "</ul>", misses]
  end

  defp spec_section(spec) do
    [
      "<p>#{h(spec.prose) |> String.replace("\n", "<br>")}</p>",
      if(spec.examples == [],
        do: "",
        else: [
          "<table class=calls><tr><th>Example</th><th>Call</th><th>Expected</th></tr>",
          Enum.map(
            spec.examples,
            &"<tr><td>#{h(&1.name)}</td><td>#{h(&1.call)}</td><td>#{h(&1.expect)}</td></tr>"
          ),
          "</table>"
        ]
      ),
      "<p>Rules:</p><ul>",
      Enum.map(spec.rules ++ spec.invariants, &"<li>#{h(&1)}</li>"),
      "</ul>"
    ]
  end

  # The outside services the app declares, and the connections admins made
  # to them, without secrets.
  defp connections_page(reviewer?) do
    services =
      for {_name, s} <- Enum.sort(Theseus.Services.all()) do
        client =
          cond do
            s.sign_in == nil and s.connect == nil -> "<span class=muted>none needed</span>"
            Theseus.OAuth.client(s.name) -> status("set up")
            true -> "<span class=\"badge bad\">not set up</span>"
          end

        urls =
          if s.urls == [],
            do: "<span class=muted>none</span>",
            else: Enum.map_join(s.urls, "<br>", &"<code>#{h(&1)}</code>")

        what =
          [if(s.sign_in, do: "sign-in"), if(s.connect, do: "connections")]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" and ")

        "<tr><td class=nw><b>#{h(s.name)}</b><div class=muted>#{if what == "", do: "requests only", else: h(what)}</div></td>" <>
          "<td>#{urls}</td><td>#{scopes(s)}</td><td>#{client}</td></tr>"
      end

    rows =
      for c <- Theseus.Connections.list() do
        last =
          case c.last_used do
            %{at: at, status: status} -> "#{h(status)}, #{short_time(at)}"
            nil -> "<span class=muted>not since the engine started</span>"
          end

        "<tr><td><b>#{h(c.service)}</b></td><td>#{h(c.domain)}</td>" <>
          "<td>#{h(c.connected_by)}<div class=muted>#{short_time(c.connected_at)}</div></td>" <>
          "<td>#{last}</td></tr>"
      end

    [
      "<h2>Connections</h2>",
      "<p class=meta>The outside services the app declares, and the connections admins made to them. ",
      "Tokens are kept encrypted next to the ledger and never shown, to people or to the app.</p>",
      "<h3>Services</h3>",
      if(services == [],
        do:
          "<p class=empty>The app declares no outside services. A services unit declares them.</p>",
        else: [
          "<table><tr><th>Service</th><th>The app may send requests to</th><th>Access it asks for</th><th>OAuth client</th></tr>",
          services,
          "</table>"
        ]
      ),
      "<h3>Connections</h3>",
      if(rows == [],
        do: "<p class=empty>None. An admin of the app connects a service from the app.</p>",
        else: [
          "<table><tr><th>Service</th><th>Domain</th><th>Connected by</th><th>Last request</th></tr>",
          rows,
          "</table>"
        ]
      ),
      api_clients(reviewer?)
    ]
  end

  # The API clients people let act as them (Theseus.Clients).
  defp api_clients(reviewer?) do
    rows =
      for g <- Theseus.Clients.grants() do
        revoke =
          if reviewer?,
            do:
              "<form method=post action=\"/grants/#{h(g.id)}/revoke\" class=inline><button class=reject>Revoke</button></form>",
            else: ""

        "<tr><td><b>#{h(g.client)}</b></td><td>#{h(g.user || "")}</td>" <>
          "<td class=\"muted nw\">#{short_time(g.created_at)}</td>" <>
          "<td class=\"muted nw\">#{if g.last_used, do: short_time(g.last_used), else: "not since the engine started"}</td><td>#{revoke}</td></tr>"
      end

    [
      "<h3>API clients</h3>",
      "<p class=muted>Clients, such as AI assistants, that people let act as them in the app. Each acts as its person until its access is revoked here or it lapses.</p>",
      if(rows == [],
        do: "<p class=empty>None yet.</p>",
        else: [
          "<table><tr><th>Client</th><th>Acting as</th><th>Allowed</th><th>Last used</th><th></th></tr>",
          rows,
          "</table>"
        ]
      )
    ]
  end

  defp scopes(s) do
    lines =
      [
        if(s.sign_in, do: "Sign-in: " <> Enum.join(s.sign_in.scopes, ", ")),
        if(s.connect, do: "Connecting: " <> Enum.join(s.connect.scopes, ", "))
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [],
      do: "<span class=muted>none</span>",
      else: Enum.map_join(lines, "", &"<div>#{h(&1)}</div>")
  end

  defp routes_page do
    branch = Branches.live()
    root = Theseus.Web.endpoint()
    routes = Theseus.RouteMap.routes(branch, root)

    rows =
      for r <- routes do
        answer =
          if r.hands_on,
            do:
              "hands on to <a href=\"/units/#{inspect(r.hands_on)}\">#{h(inspect(r.hands_on))}</a>",
            else: "<a href=\"/units/#{inspect(r.unit)}\">#{h(inspect(r.unit))}</a>"

        part = if r.htmx, do: " <span class=muted>part of a page, for htmx</span>", else: ""

        "<tr><td>#{h(r.method)}</td><td><code>#{h(r.path)}</code>#{part}</td><td>#{h(r.who || "")}</td><td>#{answer}</td></tr>"
      end

    [
      "<h2>Routes</h2>",
      "<p class=muted>The paths the app answers on branch #{h(branch)}, read from its endpoint units' patterns, ",
      "the root#{if root, do: " (#{h(inspect(root))})", else: ""} first. Who a route is for comes from the patterns alone; ",
      "checks inside a route are not shown. The engine also answers the sign-in paths under /auth.</p>",
      if(rows == [],
        do: "<p class=muted>No endpoint unit yet.</p>",
        else: [
          "<table><tr><th>Method</th><th>Path</th><th>For</th><th>Answered by</th></tr>",
          rows,
          "</table>"
        ]
      )
    ]
  end

  defp outbox_page do
    messages = Theseus.Outbox.list(200)

    how =
      case Keyword.get(Application.get_env(:theseus, :outbox, []), :adapter, :hold) do
        :webhook -> "Messages are posted to the configured webhook."
        _ -> "Messages are held here and not sent. Set THESEUS_OUTBOX_WEBHOOK to send them."
      end

    rows =
      for m <- messages do
        status =
          case m.status do
            :sent ->
              "sent #{short_time(m.sent_at)}"

            :failed ->
              "failed: #{h(m.error)}" <>
                "<form method=post action=\"/outbox/#{h(m.id)}/resend\" class=inline>" <>
                "<button type=submit>Send again</button></form>"

            :queued when m.error != nil ->
              "retrying (#{m.attempts} tried): #{h(m.error)}"

            other ->
              to_string(other)
          end

        link = if m.url, do: "<div class=muted>#{h(m.url)}</div>", else: ""

        "<tr><td>#{short_time(m.at)}<div class=muted>#{h(m.id)}</div></td><td>#{h(Enum.join(m.to, ", "))}</td>" <>
          "<td><details><summary>#{h(m.subject)}</summary><pre>#{h(m.text)}</pre>#{link}</details></td>" <>
          "<td>#{status}<div class=muted>#{h(m.source)}</div></td></tr>"
      end

    [
      "<h2>Outbox</h2>",
      "<p class=muted>Messages the app sent, newest first. #{how}</p>",
      if(rows == [],
        do: "<p class=muted>None yet.</p>",
        else: [
          "<table><tr><th>When</th><th>To</th><th>Subject</th><th>Status</th></tr>",
          rows,
          "</table>"
        ]
      )
    ]
  end

  # Which units this one calls and which call it, linked.
  defp links_note(unit) do
    links = Theseus.Introspect.graph(Branches.live())[unit] || %{calls: [], called_by: []}

    names = fn
      [] ->
        "nothing"

      list ->
        Enum.map_join(list, ", ", &"<a href=\"/units/#{inspect(&1)}\">#{h(inspect(&1))}</a>")
    end

    "<p class=muted>Calls #{names.(links.calls)}. Called by #{names.(links.called_by)}.</p>"
  end

  defp state_note(unit) do
    case Theseus.State.saved()[unit] do
      %{error: reason} when is_binary(reason) ->
        "state not saved: " <> h(reason)

      %{bytes: bytes, at: %DateTime{} = at} ->
        "state saved #{short_time(at)} (#{bytes} bytes)"

      _ ->
        if Application.get_env(:theseus, :state_file, true),
          do: "state not saved yet",
          else: "state is not kept across restarts"
    end
  end

  defp unit_page(unit, reviewer?, admin?) do
    record = Registry.fetch!(unit)
    spec = Registry.spec(unit)
    events = Ledger.events_for(unit)
    changes = Changes.list(unit: unit, limit: :all)

    [
      "<div class=eyebrow>#{record.kind} unit</div>",
      "<h2>#{h(inspect(unit))}</h2>",
      "<p class=meta>Version <code>#{Version.short(record.current_version)}</code> &middot; ",
      "#{Theseus.Consolidate.changes_since(unit)} changes since it was last rewritten ",
      "(rewritten after #{Theseus.Consolidate.threshold()})</p>",
      if(record.kind == :server,
        do: "<p class=muted>#{String.capitalize(state_note(unit))}.</p>",
        else: ""
      ),
      links_note(unit),
      owners_note(unit, admin?),
      consolidation_note(unit, changes),
      "<h3>Spec</h3>",
      if(spec, do: spec_section(Spec.describe(spec)), else: "<p class=muted>No spec.</p>"),
      "<h3>Versions of the unit</h3>",
      version_table(unit, unit, "unit", events, reviewer?),
      if(record.spec,
        do: [
          "<h3>Versions of the spec</h3>",
          version_table(unit, record.spec, "spec", events, reviewer?)
        ],
        else: ""
      ),
      "<h3>Changes</h3>",
      if(changes == [], do: "<p class=muted>None yet.</p>", else: change_table(changes)),
      "<h3>History</h3>",
      event_list(Enum.reverse(events), false)
    ]
  end

  defp consolidation_note(unit, changes) do
    waiting = Enum.count(changes, fn {c, _} -> c.status in [:shadowing, :held] end)

    if Theseus.Consolidate.changes_since(unit) > Theseus.Consolidate.threshold() and waiting > 0,
      do:
        "<p class=muted>The rewrite waits until the #{waiting} pending change(s) below are decided.</p>",
      else: ""
  end

  # Every version, newest first: when it was recorded, what brought it in,
  # and a rollback button for a reviewer.
  defp version_table(unit, module, what, events, reviewer?) do
    current = Registry.fetch!(module).current_version

    on_branches =
      Enum.group_by(Branches.list(), &Branches.current(&1.name, module), & &1.name)

    recorded =
      for %{at: at, body: {:version_recorded, %Version{unit: ^module, hash: hash}}} <- events,
          into: %{},
          do: {hash, at}

    introduced =
      Enum.reduce(events, %{}, fn
        %{body: {:promoted, ^module, _from, to, id}}, acc when is_binary(id) ->
          Map.put_new(acc, to, "<a href=\"/changes/#{id}\">#{id}</a>")

        %{body: {:unit_registered, %Theseus.Unit{module: ^module, current_version: hash}}}, acc ->
          Map.put_new(acc, hash, "imported")

        _event, acc ->
          acc
      end)

    rows =
      for %Version{hash: hash} = version <- module |> Ledger.versions_for() |> Enum.reverse() do
        action =
          cond do
            hash == current ->
              status("current")

            Version.compacted?(version) ->
              "<span class=muted>removed by compaction</span>"

            reviewer? ->
              "<form method=post action=\"/units/#{inspect(unit)}/rollback\" class=inline>" <>
                "<input type=hidden name=what value=#{what}><input type=hidden name=to value=#{hash}>" <>
                "<button>Go back to this version</button></form>"

            true ->
              ""
          end

        branches = Enum.map_join(on_branches[hash] || [], ", ", &branch_link/1)

        "<tr><td><code>#{Version.short(hash)}</code></td><td class=muted>#{time(recorded[hash])}</td>" <>
          "<td>#{introduced[hash] || ""}</td><td>#{branches}</td><td>#{action}</td></tr>"
      end

    [
      "<table><tr><th>Version</th><th>Recorded</th><th>From</th><th>Current on</th><th></th></tr>",
      rows,
      "</table>"
    ]
  end

  defp branch_link(name), do: "<a href=\"/branches/#{name}\">#{h(name)}</a>"

  defp branches_page(signed_in?) do
    previews = Map.new(Theseus.Previews.list(), &{&1.branch, &1})

    {open, closed} = Enum.split_with(Theseus.branches(), &(not &1.closed))

    rows =
      for b <- open do
        differs =
          b.differs_from_parent
          |> Enum.frequencies_by(&elem(&1, 1))
          |> Enum.map_join(", ", fn {status, n} -> "#{n} #{branch_status(status)}" end)

        preview =
          case previews[b.name] do
            %{} = p -> preview_link(b.name, p)
            nil -> ""
          end

        about =
          if b.description,
            do: "<div class=muted>#{h(b.description)}</div>",
            else: ""

        waiting =
          if b.open_changes > 0,
            do: "#{b.open_changes} waiting",
            else: "<span class=muted>none</span>"

        "<tr><td>#{branch_link(b.name)}#{if b.live, do: " " <> status("live"), else: ""}#{about}</td>" <>
          "<td>#{h(b.owner || "")}</td>" <>
          "<td>#{if b.from, do: branch_link(b.from), else: ""}</td><td class=muted>#{short_time(b.created_at)}</td>" <>
          "<td>#{waiting}</td>" <>
          "<td>#{if differs == "", do: "<span class=muted>nothing</span>", else: h(differs)}</td><td>#{preview}</td></tr>"
      end

    closed_list =
      if closed == [],
        do: "",
        else:
          "<h3>Closed</h3><p class=muted>" <>
            Enum.map_join(closed, ", ", &branch_link(&1.name)) <> "</p>"

    create =
      if signed_in?,
        do: """
        <h3>New branch</h3>
        <form method=post action="/branches" class=inline>
          <input name=name placeholder="name, e.g. cheaper-shipping"> from
          <select name=from>#{Enum.map_join(Enum.reject(Branches.list(), & &1.closed), "", &"<option>#{h(&1.name)}</option>")}</select>
          <input name=description placeholder="What it is for (optional)" maxlength=200>
          <button>Create</button>
        </form>
        """,
        else: ""

    [
      "<h2>Branches</h2>",
      "<p>The running system runs the live branch. Changes to other branches are checked and recorded, never run, unless you preview the branch or make it live.</p>",
      "<table><tr><th>Branch</th><th>Owner</th><th>Forked from</th><th>Created</th><th>Changes</th><th>Differs from its parent</th><th>Preview</th></tr>",
      rows,
      "</table>",
      closed_list,
      create
    ]
  end

  # Through the admin port, the link opens the preview with the viewer's pass.
  defp preview_link(name, p) do
    href = if Theseus.PreviewProxy.domain(), do: "/branches/#{name}/preview/open", else: p.url
    "<a href=\"#{h(href)}\">#{h(p.url)}</a>"
  end

  defp preview_data(%{data: :production}),
    do: "It reads the app's data and keeps none of its writes."

  defp preview_data(_preview),
    do:
      "Its data is made up, from the branch's seed units, and its writes last until it stops. Sign in with dev sign-in."

  defp preview_buttons(name, preview) do
    form = fn fields, label ->
      "<form method=post action=\"/branches/#{name}/preview\" class=inline>#{fields}<button>#{label}</button></form>"
    end

    case preview do
      nil ->
        [
          form.("", "Run a preview for 30 minutes"),
          form.("<input type=hidden name=keep value=true>", "Keep a preview running")
        ]

      %{kept: true} ->
        form.("<input type=hidden name=stop value=true>", "Stop the preview")

      _ ->
        [
          form.("<input type=hidden name=keep value=true>", "Keep it running"),
          form.("<input type=hidden name=stop value=true>", "Stop the preview")
        ]
    end
  end

  defp change_link(id), do: "<a href=\"/changes/#{h(id)}\"><code>#{h(id)}</code></a>"

  defp branch_status(:from), do: "changed here"
  defp branch_status(:into), do: "changed on the parent"
  defp branch_status(:conflict), do: "changed on both"
  defp branch_status(other), do: to_string(other)

  defp branch_page(name, viewer) do
    parent = Branches.parent(name)
    live? = name == Branches.live()
    preview = Enum.find(Theseus.Previews.list(), &(&1.branch == name))
    changes = Changes.list(branch: name, limit: 30)

    reviewer? = match?(%{role: r} when r in ["reviewer", "admin"], viewer)
    preview? = reviewer? or (viewer != nil and branch_creator?(name, viewer))
    closed? = Branches.closed?(name)

    actions =
      cond do
        viewer == nil ->
          ""

        closed? and preview? ->
          "<form method=post action=\"/branches/#{name}/close\" class=inline><input type=hidden name=reopen value=true><button>Reopen this branch</button></form>"

        closed? ->
          ""

        true ->
          [
            if(live? or not reviewer?,
              do: "",
              else:
                "<form method=post action=\"/branches/#{name}/live\" class=inline><button>Make this branch live</button></form>"
            ),
            if(parent,
              do: [
                "<form method=post action=\"/branches/#{name}/merge\" class=inline><input type=hidden name=into value=\"#{parent}\">",
                "<button>Propose merging into #{h(parent)}</button></form>",
                "<form method=post action=\"/branches/#{parent}/merge\" class=inline><input type=hidden name=into value=\"#{name}\">",
                "<button>Propose bringing in #{h(parent)}'s changes</button></form>"
              ],
              else: ""
            ),
            if(live? or not preview?, do: "", else: preview_buttons(name, preview)),
            if(live? or name == Branches.main() or not preview?,
              do: "",
              else:
                "<form method=post action=\"/branches/#{name}/close\" class=inline><button class=reject>Close this branch</button></form>"
            )
          ]
      end

    about =
      cond do
        preview? and not closed? ->
          "<form method=post action=\"/branches/#{name}/describe\" class=inline>" <>
            "<input name=description maxlength=200 size=60 placeholder=\"What this branch is for\" value=\"#{h(Branches.description(name) || "")}\"> <button>Save</button></form>"

        d = Branches.description(name) ->
          "<p>#{h(d)}</p>"

        true ->
          ""
      end

    owner = Branches.creator(name)

    [
      "<h2>Branch #{h(name)}#{if live?, do: " " <> status("live"), else: ""}#{if closed?, do: " " <> status("closed"), else: ""}</h2>",
      if(parent,
        do:
          "<p>Forked from #{branch_link(parent)}#{if owner, do: " by #{h(owner)}", else: ""}.</p>",
        else: ""
      ),
      if(closed?,
        do: "<p class=note>This branch is closed: it keeps its history and takes no changes.</p>",
        else: ""
      ),
      about,
      case preview do
        nil ->
          ""

        %{kept: true} ->
          "<p>Running as a preview at #{preview_link(name, preview)}, kept running. It starts again when the branch changes. #{preview_data(preview)}</p>"

        _ ->
          "<p>Running as a preview at #{preview_link(name, preview)} until #{time(preview.stops_at)}. It starts again when the branch changes. #{preview_data(preview)}</p>"
      end,
      actions,
      if(parent, do: ["<h3>Compared with #{h(parent)}</h3>", diff_table(name, parent)], else: ""),
      "<h3>Units</h3>",
      "<table><tr><th>Unit</th><th>Version</th><th>Kind</th></tr>",
      for u <- Branches.units(name), u.kind != :spec do
        name =
          if match?({:ok, _}, Registry.fetch(u.module)),
            do: "<a href=\"/units/#{inspect(u.module)}\">#{h(inspect(u.module))}</a>",
            else: "#{h(inspect(u.module))} <span class=muted>(only on this branch)</span>"

        "<tr><td>#{name}</td>" <>
          "<td>#{Version.short(u.current_version)}</td><td>#{u.kind}</td></tr>"
      end,
      "</table>",
      "<h3>Changes on this branch</h3>",
      if(changes == [], do: "<p class=muted>None yet.</p>", else: change_table(changes))
    ]
  end

  defp diff_table(name, parent) do
    rows =
      for %{unit: unit, status: status, modules: parts} <- Branches.diff(name, parent),
          status != :same do
        versions =
          Enum.map_join(parts, "<br>", fn p ->
            label = if Theseus.Unit.spec_name?(p.module), do: "spec", else: "unit"
            "#{label}: #{short(p.from)} here, #{short(p.into)} on #{h(parent)}"
          end)

        "<tr><td>#{h(inspect(unit))}</td><td>#{branch_status(status)}</td><td class=muted>#{versions}</td></tr>"
      end

    if rows == [],
      do: "<p class=muted>The same units and versions.</p>",
      else: ["<table><tr><th>Unit</th><th></th><th>Versions</th></tr>", rows, "</table>"]
  end

  defp short(nil), do: "none"
  defp short(hash), do: Version.short(hash)

  defp short_time(nil), do: ""
  defp short_time(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d %H:%M UTC")

  defp time(nil), do: ""
  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  # A time given as ISO 8601 text, as the change descriptions give it.
  defp when_text(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> short_time(at)
      _ -> h(text)
    end
  end

  defp when_text(other), do: h(other)

  # Change ids in a line of text become links. The text is escaped first.
  defp linkify(text),
    do:
      text
      |> h()
      |> to_string()
      |> String.replace(~r/\bchg_[a-z0-9]+\b/, "<a href=\"/changes/\\0\">\\0</a>")

  ## Helpers

  defp unit(name) do
    with true <- Regex.match?(~r/^[A-Z][A-Za-z0-9_.]*$/, name),
         module <- String.to_existing_atom("Elixir." <> name),
         {:ok, %{kind: kind}} when kind != :spec <- Registry.fetch(module) do
      {:ok, module}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # Who is looking: in team mode the signed-in person; in local mode
  # whoever opened the reviewer link, as an admin.
  defp viewer(conn) do
    case Team.mode() do
      :team ->
        Team.person(get_session(conn, "person"))

      :local ->
        with given when is_binary(given) <- conn.cookies[@cookie],
             true <- Plug.Crypto.secure_compare(given, token()) do
          %{email: nil, name: nil, role: "admin", local: true}
        else
          _ -> nil
        end
    end
  end

  defp reviewer?(conn), do: match?(%{role: r} when r in ["reviewer", "admin"], viewer(conn))

  defp with_reviewer(conn, fun) do
    with_person(conn, fn person ->
      if person.role in ["reviewer", "admin"],
        do: fun.(),
        else: notice(conn, 403, "Not allowed", "a reviewer or an admin does this")
    end)
  end

  defp with_admin(conn, fun) do
    with_person(conn, fn person ->
      if person.role == "admin",
        do: fun.(person),
        else: notice(conn, 403, "Not allowed", "an admin does this")
    end)
  end

  # A reviewer, an admin, or the person who made the branch.
  defp with_branch_person(conn, name, fun) do
    with_person(conn, fn person ->
      if person.role in ["reviewer", "admin"] or branch_creator?(name, person),
        do: fun.(),
        else:
          notice(conn, 403, "Not allowed", "a reviewer, an admin or the branch's maker does this")
    end)
  end

  defp branch_creator?(name, person),
    do: person[:email] != nil and Branches.creator(name) == person.email

  defp with_person(conn, fun) do
    case viewer(conn) do
      %{} = person ->
        if same_origin?(conn),
          do: fun.(person),
          else: notice(conn, 403, "Not allowed", "The form must come from this site.")

      nil ->
        how =
          if Team.mode() == :team,
            do: "Sign in first.",
            else: "Open the reviewer link printed when the app started."

        notice(conn, 403, "Not signed in", how)
    end
  end

  defp same_origin?(conn) do
    review_host = URI.parse(Theseus.ReviewSignIn.url()).host

    case get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> URI.parse(origin).host in ["127.0.0.1", "localhost", review_host]
    end
  end

  defp notice(conn, status, title, message),
    do: page(conn, status, title, "<h2>#{h(title)}</h2><p class=empty>#{h(message)}</p>")

  # What the viewer may do with a change and the changes decided with it:
  # true, {:override, reasons} (only an admin's override would approve),
  # :reject (they proposed it, and only take it back), or false.
  defp decision(conn, id) do
    with %{} = person <- viewer(conn),
         [_ | _] = set <- approval_set(id) do
      case Approvals.check(set, person) do
        :ok -> true
        {:override, reasons} -> {:override, reasons}
        {:error, _} -> if Approvals.may_reject?(set, person), do: :reject, else: false
      end
    else
      _ -> false
    end
  end

  # The changes approved or rejected together with this one.
  defp approval_set(id) do
    case Changes.get(id) do
      {:ok, %Change{group: group}, _} when group != nil ->
        for {c, _} <- Changes.group(group), do: c

      {:ok, change, _} ->
        [change]

      :error ->
        []
    end
  end

  defp token(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp status(s) do
    s = to_string(s)
    "<span class=\"badge #{badge_class(s)}\">#{h(s)}</span>"
  end

  defp badge_class(s) do
    class = %{
      "pass" => "ok",
      "set up" => "ok",
      "promoted" => "ok",
      "current" => "ok",
      "live" => "ok",
      "fail" => "bad",
      "rejected" => "bad",
      "held" => "wait",
      "shadowing" => "wait",
      "info" => "info",
      "running" => "info"
    }

    class[to_string(s)] || "muted"
  end

  defp redirect(conn, to), do: conn |> put_resp_header("location", to) |> send_resp(303, "")

  defp h(text), do: text |> to_string() |> Plug.HTML.html_escape()

  ## Team pages

  defp team_page(viewer) do
    if Team.mode() == :local do
      [
        "<h2>Team</h2>",
        "<p class=meta>This review site runs in local mode: whoever opens the reviewer link printed at start decides, and the MCP endpoint is open to this machine.</p>",
        "<p class=empty>To work as a team, set THESEUS_REVIEW_ISSUER (an OpenID Connect provider, such as https://accounts.google.com), THESEUS_REVIEW_CLIENT_ID and THESEUS_REVIEW_CLIENT_SECRET, and restart. The first person to sign in becomes an admin.</p>"
      ]
    else
      admin? = match?(%{role: "admin"}, viewer)

      rows =
        for p <- Team.people() do
          role =
            if admin?,
              do:
                "<form method=post action=\"/team/people\" class=inline><input type=hidden name=action value=role>" <>
                  "<input type=hidden name=email value=\"#{h(p.email)}\"><select name=role>" <>
                  Enum.map_join(Team.roles(), "", fn r ->
                    "<option#{if r == p.role, do: " selected", else: ""}>#{r}</option>"
                  end) <> "</select> <button>Set</button></form>",
              else: status(p.role)

          remove =
            if admin?,
              do:
                "<form method=post action=\"/team/people\" class=inline><input type=hidden name=action value=remove>" <>
                  "<input type=hidden name=email value=\"#{h(p.email)}\"><button class=reject>Remove</button></form>",
              else: ""

          "<tr><td><b>#{h(p.name || p.email)}</b><div class=muted>#{h(p.email)}</div></td><td>#{role}</td>" <>
            "<td class=\"muted nw\">#{short_time(p.added_at)}#{if p.added_by, do: "<div>by #{h(p.added_by)}</div>", else: ""}</td><td>#{remove}</td></tr>"
        end

      add =
        if admin?,
          do: """
          <h3>Add someone</h3>
          <form method=post action="/team/people" class=inline>
            <input type=hidden name=action value=add>
            <input name=email type=email placeholder="name@example.com" required>
            <select name=role>#{Enum.map_join(Team.roles(), "", &"<option>#{&1}</option>")}</select>
            <button>Add</button>
          </form>
          """,
          else: ""

      tokens =
        if admin? do
          list =
            for t <- Team.tokens(nil) do
              "<tr><td>#{h(t.label)}</td><td>#{h(t.email)}</td><td>#{if t.branch, do: branch_link(t.branch), else: "<span class=muted>the live branch</span>"}</td>" <>
                "<td class=\"muted nw\">#{short_time(t.last_used)}</td><td><form method=post action=\"/tokens/#{h(t.id)}/revoke\" class=inline>" <>
                "<input type=hidden name=back value=team><button class=reject>Revoke</button></form></td></tr>"
            end

          [
            "<h3>MCP tokens</h3>",
            if(list == [],
              do: "<p class=empty>Nobody has made one yet.</p>",
              else: [
                "<table><tr><th>Agent</th><th>Of</th><th>Works on</th><th>Last used</th><th></th></tr>",
                list,
                "</table>"
              ]
            )
          ]
        else
          ""
        end

      [
        "<h2>Team</h2>",
        "<p class=meta>Engineers propose through MCP with their own tokens and approve on branches they made. Reviewers also approve on the live branch, never what they proposed themselves. Admins also manage people and owners, and may approve over an owner's rule with a reason.</p>",
        "<table><tr><th>Person</th><th>Role</th><th>Added</th><th></th></tr>",
        rows,
        "</table>",
        add,
        tokens
      ]
    end
  end

  defp tokens_page(person, new_token) do
    shown =
      if new_token do
        """
        <div class=callout><div><b>Your new token.</b> Copy it now: it is not shown again.
        <pre>#{h(new_token)}</pre>
        Add it to Claude Code with:
        <pre>claude mcp add --transport http theseus #{h(Theseus.ReviewSignIn.url())}/mcp --header "Authorization: Bearer #{h(new_token)}"</pre></div></div>
        """
      else
        ""
      end

    rows =
      for t <- Team.tokens(person.email) do
        "<tr><td><b>#{h(t.label)}</b></td><td>#{if t.branch, do: branch_link(t.branch), else: "<span class=muted>the live branch</span>"}</td>" <>
          "<td class=\"muted nw\">#{short_time(t.created_at)}</td><td class=\"muted nw\">#{short_time(t.last_used)}</td>" <>
          "<td><form method=post action=\"/tokens/#{h(t.id)}/revoke\" class=inline><button class=reject>Revoke</button></form></td></tr>"
      end

    [
      "<h2>MCP tokens</h2>",
      "<p class=meta>One token per agent or machine. An agent using it acts as #{h(person.email)}, and its proposals are recorded as yours. A token tied to a branch works there unless the agent names another.</p>",
      shown,
      "<h3>New token</h3>",
      "<form method=post action=\"/tokens\" class=inline><input name=label placeholder=\"Laptop, Claude Code\">",
      "<select name=branch><option value=\"\">the live branch</option>",
      Enum.map_join(Branches.list(), "", &"<option>#{h(&1.name)}</option>"),
      "</select> <button>Make a token</button></form>",
      "<h3>Your tokens</h3>",
      if(rows == [],
        do: "<p class=empty>None yet.</p>",
        else: [
          "<table><tr><th>Agent</th><th>Works on</th><th>Made</th><th>Last used</th><th></th></tr>",
          rows,
          "</table>"
        ]
      )
    ]
  end

  # A rule an admin may approve over, with a reason.
  defp override_page(conn, id, reasons, person) do
    form =
      if person.role == "admin",
        do: """
        <div class=actions>
        <form method=post action="/changes/#{h(id)}/approve" class=inline>
          <input name=override placeholder="Why approve anyway" required> <button class=approve>Approve anyway</button>
        </form>
        <p class=muted>The ledger records that you approved over the rule, with your reason.</p>
        </div>
        """,
        else: "<p class=note>Ask one of the owners, or an admin, to approve it.</p>"

    status = if person.role == "admin", do: 200, else: 403

    page(conn, status, "Not approved yet", [
      "<h2>Not approved yet</h2>",
      "<ul>",
      Enum.map(reasons, &"<li>#{h(&1)}</li>"),
      "</ul>",
      form
    ])
  end

  defp owners_note(unit, admin?) do
    if Team.mode() == :team do
      owners = Team.owners(unit)

      line =
        if owners == [],
          do: "No owners.",
          else:
            "Owned by #{Enum.join(owners, ", ")}: one of them approves its spec, schema and merge changes."

      form =
        if admin?,
          do:
            "<form method=post action=\"/units/#{inspect(unit)}/owners\" class=inline><input name=owners value=\"#{h(Enum.join(owners, ", "))}\" placeholder=\"owner emails\">" <>
              " <button>Set owners</button></form>",
          else: ""

      "<p class=muted>#{h(line)}</p>#{form}"
    else
      ""
    end
  end

  ## Layout

  @nav [
    {"/", "Dashboard", :grid},
    {"/history", "History", :clock},
    {"/branches", "Branches", :branch},
    {"/routes", "Routes", :signpost},
    {"/connections", "Connections", :link},
    {"/outbox", "Outbox", :send},
    {"/team", "Team", :user}
  ]

  @icons %{
    grid:
      ~s(<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>),
    clock: ~s(<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>),
    branch:
      ~s(<path d="M6 3v12"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/>),
    signpost: ~s(<path d="M12 3v18"/><path d="M5 6h11l3 3-3 3H5z"/>),
    link:
      ~s(<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>),
    send: ~s(<path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4z"/>),
    user: ~s(<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>),
    eye:
      ~s(<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>)
  }

  # A mast, two sails and a hull: the ship of Theseus.
  @sail ~s(<path d="M12 3v14"/><path d="M12 4.5l6 9.5h-6"/><path d="M12 7.5L7 14h5"/><path d="M4 18h16l-2.5 3h-11z" fill="#fff" stroke="none"/>)

  @mark ~s(<svg viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">#{@sail}</svg>)

  @favicon "data:image/svg+xml," <>
             URI.encode(
               ~s|<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5b54e8"/><stop offset="1" stop-color="#c058f3"/></linearGradient></defs><rect width="32" height="32" rx="8" fill="url(#g)"/><g transform="translate(4 4)" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">#{@sail}</g></svg>|,
               &URI.char_unreserved?/1
             )

  @css """
  :root{--bg:#f5f6f8;--surface:#fff;--surface-2:#f8f9fb;--sunken:#eef0f4;--fg:#101828;--fg-2:#344054;--muted:#667085;--line:#e4e7ec;--line-2:#eef0f3;--accent:#5b54e8;--accent-soft:#efeefe;--ok:#067647;--ok-solid:#12a35f;--bad:#d92d20;--wait:#b54708;--info:#175cd3;--shadow:0 1px 2px rgba(16,24,40,.05);--shadow-2:0 4px 12px rgba(16,24,40,.06),0 1px 3px rgba(16,24,40,.06);--radius:12px;color-scheme:light}
  @media (prefers-color-scheme:dark){:root{--bg:#0c0e13;--surface:#13161d;--surface-2:#171b23;--sunken:#1c212b;--fg:#eceef3;--fg-2:#c6cbd6;--muted:#8a93a6;--line:#262c38;--line-2:#1f242e;--accent:#8f88ff;--accent-soft:#211f42;--ok:#47cd89;--ok-solid:#139c5b;--bad:#f97066;--wait:#fdb022;--info:#53b1fd;--shadow:0 1px 2px rgba(0,0,0,.35);--shadow-2:0 4px 14px rgba(0,0,0,.35);color-scheme:dark}}
  *{box-sizing:border-box}
  body{margin:0;font:14px/1.55 -apple-system,BlinkMacSystemFont,Inter,"Segoe UI",system-ui,sans-serif;color:var(--fg);background:var(--bg);-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums}
  a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
  code,pre{font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,monospace;font-size:12.5px}
  .side{position:fixed;inset:0 auto 0 0;width:232px;display:flex;flex-direction:column;padding:20px 14px 18px;background:var(--surface);border-right:1px solid var(--line)}
  .brand{display:flex;align-items:center;gap:11px;padding:0 8px 22px;color:var(--fg);font-weight:650;font-size:16px;letter-spacing:-.01em;line-height:1.2}
  .brand:hover{text-decoration:none}
  .brand small{display:block;font-weight:500;font-size:11.5px;color:var(--muted);letter-spacing:0}
  .mark{width:34px;height:34px;flex:none;border-radius:10px;background:linear-gradient(135deg,#5b54e8,#c058f3);display:grid;place-items:center;box-shadow:0 3px 10px rgba(91,84,232,.35)}
  .side nav{display:flex;flex-direction:column;gap:2px}
  .side nav a{display:flex;align-items:center;gap:10px;padding:7px 10px;border-radius:8px;color:var(--fg-2);font-weight:500}
  .side nav a:hover{background:var(--sunken);text-decoration:none}
  .side nav a.on{background:var(--accent-soft);color:var(--accent)}
  .side svg.i{width:17px;height:17px;flex:none}
  .count{margin-left:auto;min-width:20px;padding:0 6px;border-radius:999px;background:var(--accent);color:#fff;font-size:11.5px;font-weight:650;text-align:center;line-height:19px}
  .foot{margin-top:auto;display:flex;flex-direction:column;gap:9px;padding:14px 10px 0;border-top:1px solid var(--line);font-size:12.5px;color:var(--muted)}
  .foot div{display:flex;align-items:center;gap:8px}
  .foot a{color:var(--fg-2);font-weight:550}
  .foot svg.i{width:15px;height:15px}
  .dot{display:inline-block;width:7px;height:7px;margin:0 4px;border-radius:50%;background:var(--ok-solid);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok-solid) 22%,transparent)}
  main{margin-left:232px;padding:34px 44px 72px;max-width:1260px}
  h2{font-size:24px;line-height:1.25;font-weight:680;letter-spacing:-.02em;margin:0 0 6px}
  h3{font-size:15px;font-weight:650;letter-spacing:-.005em;margin:34px 0 10px}
  h4{font-size:13px;font-weight:620;color:var(--fg-2);margin:20px 0 8px}
  p{margin:8px 0}
  ul{padding-left:20px}li{margin:3px 0}
  .muted{color:var(--muted)}td div.muted{font-size:12.5px;margin-top:2px}
  .meta{color:var(--muted);margin:4px 0 22px}
  .meta a{font-weight:550}
  .eyebrow{font-size:12px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);margin-bottom:8px}
  .eyebrow code,.eyebrow a{text-transform:none;letter-spacing:0;font-size:12px}
  .badge{display:inline-flex;align-items:center;gap:6px;white-space:nowrap;font-size:12px;font-weight:560;line-height:21px;padding:0 9px;border-radius:999px;background:color-mix(in srgb,currentColor 12%,transparent);vertical-align:1px}
  .badge::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}
  .ok{color:var(--ok)}.bad{color:var(--bad)}.wait{color:var(--wait)}.info{color:var(--info)}
  table{width:100%;border-collapse:separate;border-spacing:0;margin:10px 0 6px;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);box-shadow:var(--shadow);overflow:hidden}
  th{font-size:11.5px;font-weight:600;letter-spacing:.05em;text-transform:uppercase;color:var(--muted);background:var(--surface-2);text-align:left;padding:10px 14px;border-bottom:1px solid var(--line);white-space:nowrap}
  td{padding:11px 14px;text-align:left;vertical-align:top;border-top:1px solid var(--line-2);overflow-wrap:anywhere}
  tr:nth-child(2) td{border-top:0}
  tr:hover td{background:var(--surface-2)}
  td.muted{font-size:13px}
  a.title{color:var(--fg);font-weight:560}a.title:hover{color:var(--accent);text-decoration:none}
  .bar{display:block;max-width:110px;height:4px;margin-top:7px;border-radius:99px;background:var(--sunken);overflow:hidden}
  .bar i{display:block;height:100%;border-radius:inherit;background:var(--accent)}
  .bar.full i{background:var(--wait)}
  .tiles{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin:24px 0 6px}
  .tile{display:block;padding:16px 18px;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);box-shadow:var(--shadow);color:var(--fg);transition:border-color .15s,box-shadow .15s,transform .15s}
  a.tile:hover{text-decoration:none;border-color:color-mix(in srgb,var(--accent) 45%,var(--line));box-shadow:var(--shadow-2);transform:translateY(-1px)}
  .tile .label{font-size:12.5px;font-weight:550;color:var(--muted)}
  .tile .n{font-size:30px;font-weight:680;letter-spacing:-.03em;line-height:1.15;margin-top:6px}
  .tile .sub{font-size:12px;color:var(--muted);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .tile.hot{background:linear-gradient(135deg,#5b54e8,#a855f7);border-color:transparent;color:#fff;box-shadow:0 6px 18px rgba(91,84,232,.3)}
  .tile.hot .label,.tile.hot .sub{color:rgba(255,255,255,.85)}
  .empty{margin:10px 0;padding:22px;text-align:center;color:var(--muted);background:var(--surface);border:1px dashed var(--line);border-radius:var(--radius)}
  .note{padding:10px 14px;border-radius:10px;background:var(--sunken);color:var(--muted)}
  ul.stages{list-style:none;padding:0;margin:10px 0;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);box-shadow:var(--shadow);overflow:hidden}
  ul.stages li{display:grid;grid-template-columns:76px 1fr;gap:12px;align-items:start;margin:0;padding:10px 14px;border-top:1px solid var(--line-2)}
  ul.stages li:first-child{border-top:0}
  ul.stages b{font-weight:600}
  ul.stages .badge{justify-self:start;margin-top:1px}
  ul.diff{padding:0}
  li.add,li.del,li.chg{list-style:none;margin:6px 0;padding:8px 12px;border-left:3px solid;border-radius:8px}
  li.add{border-color:var(--ok);background:color-mix(in srgb,var(--ok) 8%,var(--surface))}
  li.del{border-color:var(--bad);background:color-mix(in srgb,var(--bad) 8%,var(--surface))}
  li.chg{border-color:var(--wait);background:color-mix(in srgb,var(--wait) 8%,var(--surface))}
  blockquote{margin:10px 0;padding:14px 18px;background:var(--surface);border:1px solid var(--line);border-left:3px solid var(--accent);border-radius:10px;color:var(--fg-2);box-shadow:var(--shadow)}
  pre{white-space:pre-wrap;word-break:break-word;margin:8px 0;padding:12px 14px;background:var(--sunken);border:1px solid var(--line);border-radius:10px}
  details summary{cursor:pointer}
  .callout{display:flex;align-items:center;justify-content:space-between;gap:12px 20px;flex-wrap:wrap;margin:16px 0 10px;padding:14px 16px;background:var(--accent-soft);border:1px solid color-mix(in srgb,var(--accent) 35%,var(--line));border-radius:var(--radius)}
  a.button{display:inline-flex;align-items:center;padding:8px 14px;border-radius:8px;background:var(--accent);color:#fff;font-weight:560;white-space:nowrap}
  a.button:hover{text-decoration:none;filter:brightness(1.08)}
  ul.members{list-style:none;padding:0;margin:10px 0;display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:8px}
  ul.members li{display:flex;align-items:center;gap:8px;margin:0;padding:9px 12px;background:var(--surface);border:1px solid var(--line);border-radius:10px}
  ul.members .badge{margin-left:auto}
  table.calls td{font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,monospace;font-size:12px;line-height:1.5}
  table.calls td:first-child{width:46%}
  table.group td:first-child,td.nw{white-space:nowrap}
  table.group td:last-child{line-height:2}
  table.group .badge{margin:0 2px 0 0}
  .chips{display:flex;flex-wrap:wrap;gap:6px;margin:12px 0 18px}
  .chips a{padding:3px 11px;border-radius:999px;background:var(--surface);border:1px solid var(--line);color:var(--fg-2);font-size:12.5px}
  .chips a:hover{border-color:var(--accent);color:var(--accent);text-decoration:none}
  .chips a.on{background:var(--accent-soft);border-color:transparent;color:var(--accent);font-weight:550}
  button,input,select{font:inherit;font-size:13.5px}
  button{display:inline-flex;align-items:center;gap:6px;padding:7px 14px;border-radius:8px;border:1px solid var(--line);background:var(--surface);color:var(--fg);font-weight:560;cursor:pointer;box-shadow:var(--shadow);transition:background .12s,border-color .12s}
  button:hover{background:var(--surface-2);border-color:color-mix(in srgb,var(--fg) 22%,var(--line))}
  button:active{transform:translateY(1px)}
  button.approve{background:var(--ok-solid);border-color:transparent;color:#fff;box-shadow:0 1px 2px rgba(16,24,40,.12),inset 0 1px 0 rgba(255,255,255,.18)}
  button.approve:hover{background:color-mix(in srgb,var(--ok-solid) 86%,#000)}
  button.reject{color:var(--bad)}
  input,select{padding:7px 10px;border-radius:8px;border:1px solid var(--line);background:var(--surface);color:var(--fg)}
  input{min-width:220px}
  input:focus,select:focus,button:focus-visible{outline:2px solid color-mix(in srgb,var(--accent) 55%,transparent);outline-offset:1px}
  .inline{display:inline-flex;align-items:center;gap:8px;margin:4px 8px 4px 0}
  .actions{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin:20px 0;padding:14px 16px;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);box-shadow:var(--shadow-2)}
  .actions .inline{margin:0}.actions p{flex-basis:100%;margin:0}
  @media (max-width:860px){
  .side{position:static;width:auto;flex-direction:row;flex-wrap:wrap;align-items:center;gap:10px;padding:12px 16px;border-right:0;border-bottom:1px solid var(--line)}
  .brand{padding:0}
  .side nav{order:3;flex:1 1 100%;flex-direction:row;overflow-x:auto;scrollbar-width:none}
  .side nav::-webkit-scrollbar{display:none}
  .side nav a{white-space:nowrap}
  .foot{margin:0 0 0 auto;padding:0;border:0;flex-direction:row;gap:14px}
  main{margin-left:0;padding:22px 16px 56px}
  table{display:block;overflow-x:auto}
  .tiles{grid-template-columns:repeat(2,minmax(0,1fr))}
  }
  """

  defp page(conn, status, title, body, opts \\ []) do
    refresh =
      if opts[:refresh], do: "<meta http-equiv=refresh content=#{opts[:refresh]}>", else: ""

    title = if title == "Theseus", do: title, else: "#{title} · Theseus"

    html = [
      "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content=\"width=device-width, initial-scale=1\">",
      refresh,
      "<title>#{h(title)}</title><link rel=icon href=\"#{@favicon}\"><style>",
      @css,
      "</style></head><body>",
      sidebar(conn),
      "<main>",
      body,
      "</main></body></html>"
    ]

    conn |> put_resp_content_type("text/html") |> send_resp(status, html)
  end

  defp sidebar(conn) do
    section = section(conn.request_path)
    waiting = Changes.list(status: :held) |> collapse_groups() |> length()

    links =
      for {path, label, icon} <- @nav do
        count =
          if path == "/" and waiting > 0, do: "<span class=count>#{waiting}</span>", else: ""

        on = if path == section, do: " class=on", else: ""
        "<a href=\"#{path}\"#{on}>#{icon(icon)}<span>#{label}</span>#{count}</a>"
      end

    who =
      case {Team.mode(), viewer(conn)} do
        {:team, %{} = p} ->
          "<div>#{icon(:user)}#{h(p.email)} &middot; #{p.role}</div>" <>
            "<div><a href=\"/tokens\">MCP tokens</a> &middot; <form method=post action=\"/sign-out\" class=inline><button>Sign out</button></form></div>"

        {:team, nil} ->
          "<div>#{icon(:eye)}<a href=\"/sign-in\">Sign in</a></div>"

        {:local, %{}} ->
          "<div>#{icon(:user)}Signed in as reviewer</div>"

        {:local, nil} ->
          "<div title=\"Open the reviewer link printed when the app started\">#{icon(:eye)}Read only</div>"
      end

    [
      "<aside class=side><a href=\"/\" class=brand><span class=mark>#{@mark}</span>",
      "<span>Theseus<small>Review</small></span></a><nav>",
      links,
      "</nav><div class=foot><div><span class=dot></span>Running #{branch_link(Branches.live())}</div>",
      who,
      "</div></aside>"
    ]
  end

  # The menu entry a page belongs to: change, group and unit pages are
  # reached from the dashboard.
  defp section(path) do
    case String.split(path, "/", trim: true) do
      [top | _]
      when top in ["history", "branches", "routes", "connections", "outbox", "team", "tokens"] ->
        "/" <> top

      _ ->
        "/"
    end
  end

  defp icon(name) do
    ~s(<svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{@icons[name]}</svg>)
  end
end
