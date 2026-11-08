defmodule Theseus.TeamTest do
  @moduledoc "Team mode: review sign-in, roles, MCP tokens, approval rules and the admin override."

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test, only: [conn: 2, conn: 3, recycle_cookies: 2]
  import Theseus.TestHelpers

  alias Theseus.{Approvals, Branches, Changes, FakeOAuth, Ledger, Team}

  setup_all do
    {pid, base} = FakeOAuth.start()
    on_exit(fn -> Process.exit(pid, :normal) end)
    %{base: base}
  end

  setup %{base: base} do
    before = snapshot()
    sign_in = Application.get_env(:theseus, :review_sign_in)
    put_back = FakeOAuth.use(base)

    Application.put_env(
      :theseus,
      :clients,
      Map.put(Application.get_env(:theseus, :clients), "theseus_review",
        client_id: "test-client",
        client_secret: "test-secret"
      )
    )

    Application.put_env(:theseus, :review_sign_in, issuer: "https://accounts.example")
    fresh_team()

    on_exit(fn ->
      if sign_in,
        do: Application.put_env(:theseus, :review_sign_in, sign_in),
        else: Application.delete_env(:theseus, :review_sign_in)

      put_back.()
      fresh_team()
      restore(before)
    end)

    :ok
  end

  defp fresh_team do
    :ok = Supervisor.terminate_child(Theseus.Supervisor, Theseus.Team)
    {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, Theseus.Team)
  end

  defp call(conn), do: Theseus.Admin.Router.call(conn, Theseus.Admin.Router.init([]))

  # Signs in through the review site and the fake provider. Returns the
  # callback's conn, whose cookies later requests carry.
  defp sign_in(email) do
    start = call(conn(:get, "/sign-in"))
    assert start.status == 302
    [location] = get_resp_header(start, "location")
    assert location =~ "https://accounts.example/o/oauth2/v2/auth?"
    q = URI.decode_query(URI.parse(location).query)
    assert q["redirect_uri"] == "http://127.0.0.1:4001/sign-in/callback"

    code = "code-#{System.unique_integer([:positive])}"
    FakeOAuth.expect(code, q["code_challenge"], FakeOAuth.claims(q["nonce"], %{"email" => email}))

    conn(:get, "/sign-in/callback?" <> URI.encode_query(%{"state" => q["state"], "code" => code}))
    |> recycle_cookies(start)
    |> call()
  end

  defp get(path, as), do: conn(:get, path) |> recycle_cookies(as) |> call()
  defp post(path, params, as), do: conn(:post, path, params) |> recycle_cookies(as) |> call()

  defp propose(fields) do
    {:ok, change, _} = Changes.propose(proposal(fields))
    {change, _} = settle(change.id)
    assert change.status == :held
    change
  end

  defp by(email), do: %{kind: :mcp, client: "test-agent", person: email}

  describe "people" do
    test "the first person to sign in is an admin; then only people added or on a listed domain" do
      assert {:ok, %{role: "admin"}} = Team.sign_in(%{email: "Ada@Example.com", name: "Ada"})
      assert Team.person("ada@example.com").name == "Ada"

      assert {:error, why} = Team.sign_in(%{email: "bob@example.com"})
      assert why =~ "not on this team"

      assert :ok = Team.add("bob@example.com", "reviewer", "ada@example.com")
      assert {:ok, %{role: "reviewer"}} = Team.sign_in(%{email: "bob@example.com"})

      config = Application.get_env(:theseus, :review_sign_in)
      Application.put_env(:theseus, :review_sign_in, config ++ [domains: ["team.example"]])
      assert {:ok, %{role: "engineer"}} = Team.sign_in(%{email: "cy@team.example"})
      assert {:error, _} = Team.sign_in(%{email: "dee@other.example"})
    end

    test "the last admin stays" do
      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})

      assert {:error, "the last admin stays an admin"} =
               Team.set_role("ada@example.com", "engineer", "ada@example.com")

      assert {:error, _} = Team.remove("ada@example.com", "ada@example.com")

      :ok = Team.add("bob@example.com", "admin", "ada@example.com")
      assert :ok = Team.set_role("ada@example.com", "engineer", "bob@example.com")
      assert {:error, _} = Team.add("bob@example.com", "engineer", "bob@example.com")
      assert {:error, _} = Team.add("cy@example.com", "boss", "bob@example.com")
    end

    test "tokens are kept hashed, checked, tied to a branch, and revoked" do
      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})
      assert {:error, "no branch named nope"} = Team.create_token("ada@example.com", "x", "nope")
      assert {:error, _} = Team.create_token("nobody@example.com", "x")

      {:ok, token, meta} = Team.create_token("ada@example.com", "laptop")
      assert "tmc_" <> _ = token
      refute Map.has_key?(meta, :hash)
      assert [%{label: "laptop", last_used: nil}] = Team.tokens("ada@example.com")

      assert {:ok, %{email: "ada@example.com"}, %{id: id, branch: nil}} = Team.verify_token(token)
      assert [%{last_used: %DateTime{}}] = Team.tokens("ada@example.com")
      assert :error = Team.verify_token(token <> "x")

      assert {:error, _} = Team.revoke_token(id, "someone@example.com")
      assert :ok = Team.revoke_token(id, "ada@example.com")
      assert :error = Team.verify_token(token)
    end

    test "removing someone revokes their tokens" do
      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})
      :ok = Team.add("bob@example.com", "engineer", "ada@example.com")
      {:ok, token, _} = Team.create_token("bob@example.com", "laptop")
      :ok = Team.remove("bob@example.com", "ada@example.com")
      assert :error = Team.verify_token(token)
      assert Team.tokens(nil) == []
    end
  end

  describe "the review site" do
    test "shows nothing until someone signs in" do
      assert %{status: 303} = conn = call(conn(:get, "/"))
      assert get_resp_header(conn, "location") == ["/sign-in"]
      assert %{status: 303} = call(conn(:get, "/units/Sample.Pricing"))
    end

    test "signs people in with the provider found by discovery" do
      ada = sign_in("ada@example.com")
      assert ada.status == 303
      assert get_resp_header(ada, "location") == ["/"]

      home = get("/", ada)
      assert home.status == 200
      assert home.resp_body =~ "ada@example.com &middot; admin"

      # Someone not on the team is turned away.
      stranger = sign_in("stranger@elsewhere.example")
      assert stranger.status == 401
      assert stranger.resp_body =~ "not on this team"
    end

    test "on https the session cookie is sent only over TLS, and MCP accepts the site's origin" do
      config = Application.get_env(:theseus, :review_sign_in)
      Application.put_env(:theseus, :review_sign_in, config ++ [url: "https://review.example"])

      start = call(conn(:get, "/sign-in"))
      assert start.resp_cookies["_theseus_review"].secure
      [location] = get_resp_header(start, "location")

      assert URI.decode_query(URI.parse(location).query)["redirect_uri"] ==
               "https://review.example/sign-in/callback"

      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})
      {:ok, token, _} = Team.create_token("ada@example.com", "agent")
      auth = {"authorization", "Bearer " <> token}
      assert {200, _} = modern("tools/list", %{}, [auth, {"origin", "https://review.example"}])
      assert {403, _} = modern("tools/list", %{}, [auth, {"origin", "https://evil.example"}])
    end

    test "a callback that does not match its sign-in is refused" do
      start = call(conn(:get, "/sign-in"))

      wrong =
        conn(:get, "/sign-in/callback?state=nope&code=x")
        |> recycle_cookies(start)
        |> call()

      assert wrong.status == 400
      assert call(conn(:get, "/sign-in/callback?state=x&code=y")).status == 400
    end

    test "an admin adds people and sets owners; others cannot" do
      ada = sign_in("ada@example.com")

      assert post(
               "/team/people",
               %{"action" => "add", "email" => "bob@example.com", "role" => "engineer"},
               ada
             ).status == 303

      assert get("/team", ada).resp_body =~ "bob@example.com"

      bob = sign_in("bob@example.com")

      assert post(
               "/team/people",
               %{"action" => "add", "email" => "cy@example.com", "role" => "admin"},
               bob
             ).status == 403

      assert post("/units/Sample.Pricing/owners", %{"owners" => "bob@example.com"}, bob).status ==
               403

      assert post(
               "/units/Sample.Pricing/owners",
               %{"owners" => "bob@example.com, nobody@x.example"},
               ada
             ).status == 422

      assert post("/units/Sample.Pricing/owners", %{"owners" => "bob@example.com"}, ada).status ==
               303

      assert Team.owners(Sample.Pricing) == ["bob@example.com"]
      assert get("/units/Sample.Pricing", ada).resp_body =~ "Owned by bob@example.com"
    end

    test "engineers make branches and decide their own changes there" do
      ada = sign_in("ada@example.com")
      :ok = Team.add("eng@example.com", "engineer", "ada@example.com")
      eng = sign_in("eng@example.com")
      branch = "t#{System.unique_integer([:positive])}"

      made =
        post("/branches", %{"name" => branch, "from" => "main", "description" => "notes"}, eng)

      assert made.status == 303
      assert Branches.creator(branch) == "eng@example.com"
      assert get("/branches", ada).resp_body =~ "notes"
      page = get("/branches/#{branch}", eng).resp_body
      assert page =~ "Run a preview"
      refute page =~ "Make this branch live"
      assert get("/branches/#{branch}", ada).resp_body =~ "Make this branch live"

      mine =
        propose(
          branch: branch,
          unit_source: cheaper_shipping_unit(),
          proposer: by("eng@example.com")
        )

      assert get("/changes/#{mine.id}", eng).resp_body =~ "class=approve"

      # On the live branch an engineer only takes back what they proposed.
      live = propose(unit_source: cheaper_shipping_unit(), proposer: by("eng@example.com"))
      html = get("/changes/#{live.id}", eng).resp_body
      refute html =~ "class=approve"
      assert html =~ "you may reject it"
      assert post("/changes/#{live.id}/approve", %{}, eng).status == 403
      assert post("/changes/#{live.id}/reject", %{}, eng).status == 303

      assert post("/changes/#{mine.id}/approve", %{}, eng).status == 303
      assert {:ok, %{status: :promoted}, _} = Changes.get(mine.id)

      :ok = Team.add("eng2@example.com", "engineer", "ada@example.com")
      other = sign_in("eng2@example.com")
      assert post("/branches/#{branch}/close", %{}, other).status == 403
      assert post("/branches/#{branch}/close", %{}, eng).status == 303
      assert Branches.closed?(branch)
      assert get("/branches/#{branch}", eng).resp_body =~ "Reopen this branch"
    end

    test "a token is shown once, on the tokens page" do
      ada = sign_in("ada@example.com")
      made = post("/tokens", %{"label" => "laptop"}, ada)
      assert made.status == 200
      [token] = Regex.run(~r/tmc_[A-Za-z0-9_-]+/, made.resp_body)
      assert {:ok, _, _} = Team.verify_token(token)

      listed = get("/tokens", ada)
      assert listed.resp_body =~ "laptop"
      refute listed.resp_body =~ token
    end
  end

  describe "previews through the admin port" do
    setup do
      previews = Application.get_env(:theseus, :previews, [])
      Application.put_env(:theseus, :previews, Keyword.put(previews, :domain, "preview.test"))

      on_exit(fn ->
        Application.put_env(:theseus, :previews, previews)
        for p <- Theseus.Previews.list(), do: Theseus.Previews.stop(p.branch)
      end)

      :ok
    end

    defp to_preview(method, url, opts \\ []) do
      conn =
        case opts[:json] do
          nil ->
            conn(method, url)

          body ->
            conn(method, url, JSON.encode!(body))
            |> put_req_header("content-type", "application/json")
        end

      conn = Enum.reduce(opts[:headers] || [], conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      conn = if opts[:as], do: recycle_cookies(conn, opts[:as]), else: conn
      call(conn)
    end

    test "only the team reaches a preview, with a pass from the review site" do
      ada = sign_in("ada@example.com")
      :ok = Team.add("eng@example.com", "engineer", "ada@example.com")
      branch = "t_#{System.unique_integer([:positive])}"
      label = String.replace(branch, "_", "-")
      :ok = Branches.create(branch, "main", by: "ada@example.com")
      {:ok, preview} = Theseus.Previews.start(branch)
      assert preview.url == "http://#{label}.preview.test:4001"

      basket = %{"items" => [%{"sku" => "a", "qty" => 1, "unit_cents" => 1000}]}
      price = "http://#{label}.preview.test/price"

      assert to_preview(:post, price, json: basket).status == 403
      assert to_preview(:get, "http://nothing.preview.test/").status == 404

      # The branch page's link gives a pass, which the preview keeps in a cookie.
      opened = get("/branches/#{branch}/preview/open", ada)
      assert opened.status == 303
      [enter] = get_resp_header(opened, "location")
      assert enter =~ "http://#{label}.preview.test:4001/_theseus/enter?pass="

      entered = to_preview(:get, String.replace(enter, ":4001", ""))
      assert entered.status == 303
      assert entered.resp_cookies["_theseus_preview"].http_only

      answer = to_preview(:post, price, json: basket, as: entered)
      assert answer.status == 200
      assert %{"total_cents" => _} = JSON.decode!(answer.resp_body)

      # An agent sends a pass in a header; a pass is for one branch and one person.
      pass = Theseus.PreviewProxy.pass(branch, "eng@example.com")

      assert to_preview(:post, price, json: basket, headers: [{"x-theseus-preview", pass}]).status ==
               200

      other = Theseus.PreviewProxy.pass("main", "eng@example.com")

      assert to_preview(:post, price, json: basket, headers: [{"x-theseus-preview", other}]).status ==
               403

      :ok = Team.remove("eng@example.com", "ada@example.com")

      assert to_preview(:post, price, json: basket, headers: [{"x-theseus-preview", pass}]).status ==
               403

      # Other hosts reach the review site as before.
      assert get("/branches/#{branch}", ada).status == 200
    end
  end

  describe "MCP" do
    test "needs a token in team mode, and the token's person proposes" do
      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})
      {:ok, token, _} = Team.create_token("ada@example.com", "agent")

      assert {401, %{"error" => %{"message" => why}}} = modern("tools/list")
      assert why =~ "MCP token"
      assert {401, _} = modern("tools/list", %{}, [{"authorization", "Bearer tmc_wrong"}])

      args = %{
        "unit" => "Sample.Pricing",
        "intent" => "cheaper shipping",
        "unit_source" => cheaper_shipping_unit(),
        "spec_source" => cheaper_shipping_spec()
      }

      {200, proposed} =
        modern("tools/call", %{"name" => "propose_change", "arguments" => args}, [
          {"authorization", "Bearer " <> token}
        ])

      id = proposed["result"]["structuredContent"]["id"]
      {change, _} = settle(id)
      assert change.proposer.person == "ada@example.com"

      assert %{by: "ada@example.com"} =
               Enum.find(Ledger.events(), &match?(%{body: {:change_proposed, %{id: ^id}}}, &1))
    end

    test "a token tied to a branch works there" do
      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})
      branch = "t#{System.unique_integer([:positive])}"
      :ok = Branches.create(branch, "main", by: "ada@example.com")
      {:ok, token, _} = Team.create_token("ada@example.com", "agent", branch)

      args = %{
        "unit" => "Sample.Pricing",
        "intent" => "on a branch",
        "unit_source" => cheaper_shipping_unit()
      }

      {200, proposed} =
        modern("tools/call", %{"name" => "propose_change", "arguments" => args}, [
          {"authorization", "Bearer " <> token}
        ])

      {:ok, change, _} = Changes.get(proposed["result"]["structuredContent"]["id"])
      assert change.branch == branch
    end
  end

  describe "approval rules" do
    setup do
      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})
      :ok = Team.add("rev@example.com", "reviewer", "ada@example.com")
      :ok = Team.add("eng@example.com", "engineer", "ada@example.com")
      :ok = Team.add("own@example.com", "reviewer", "ada@example.com")
      :ok
    end

    test "on the live branch a reviewer other than the proposer approves" do
      c = propose(unit_source: cheaper_shipping_unit(), proposer: by("rev@example.com"))

      assert {:error, why} = Approvals.check([c], Team.person("eng@example.com"))
      assert why =~ "you are an engineer"
      assert {:override, [why]} = Approvals.check([c], Team.person("rev@example.com"))
      assert why =~ "you proposed it"
      assert :ok = Approvals.check([c], Team.person("own@example.com"))
      assert {:error, "sign in to approve"} = Approvals.check([c], nil)

      # The proposer may still reject their own change; another engineer may not.
      assert Approvals.may_reject?([c], Team.person("rev@example.com"))
      refute Approvals.may_reject?([c], Team.person("eng@example.com"))
    end

    test "a spec change to an owned unit needs an owner" do
      :ok = Team.set_owners(Sample.Pricing, ["own@example.com"], "ada@example.com")

      spec_change =
        propose(
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec(),
          proposer: by("eng@example.com")
        )

      assert {:override, [why]} = Approvals.check([spec_change], Team.person("rev@example.com"))
      assert why =~ "Sample.Pricing is owned by own@example.com"
      assert :ok = Approvals.check([spec_change], Team.person("own@example.com"))
    end

    test "a code-only change to an owned unit does not need an owner" do
      :ok = Team.set_owners(Sample.Pricing, ["own@example.com"], "ada@example.com")
      c = propose(unit_source: cheaper_shipping_unit(), proposer: by("eng@example.com"))
      assert :ok = Approvals.check([c], Team.person("rev@example.com"))
    end

    test "the engineer who made a branch approves their own changes there" do
      branch = "t#{System.unique_integer([:positive])}"
      :ok = Branches.create(branch, "main", by: "eng@example.com")
      assert Branches.creator(branch) == "eng@example.com"

      c =
        propose(
          branch: branch,
          unit_source: cheaper_shipping_unit(),
          proposer: by("eng@example.com")
        )

      :ok = Team.add("eng2@example.com", "engineer", "ada@example.com")
      assert :ok = Approvals.check([c], Team.person("eng@example.com"))
      assert {:error, _} = Approvals.check([c], Team.person("eng2@example.com"))
    end

    test "local mode leaves every decision to the reviewer link" do
      Application.delete_env(:theseus, :review_sign_in)
      c = propose(unit_source: cheaper_shipping_unit(), proposer: by("rev@example.com"))
      assert Team.mode() == :local
      assert :ok = Approvals.check([c], nil)
    end
  end

  describe "notices" do
    defp notices(since) do
      for m <- Theseus.Outbox.list(1000), m.source == "theseus", m.id not in since, do: m
    end

    defp seen, do: Enum.map(Theseus.Outbox.list(1000), & &1.id)

    # Notices are queued by the changes process just after a change's status
    # changes, so a test that sees the status may look a moment early.
    defp notices_soon(since, keep \\ fn _ -> true end) do
      Enum.find_value(1..200, [], fn _ ->
        case Enum.filter(notices(since), keep) do
          [] ->
            Process.sleep(10)
            nil

          found ->
            found
        end
      end)
    end

    test "the people who may approve hear that a change waits, and a branch's owner that its parent moved" do
      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})
      :ok = Team.add("rev@example.com", "reviewer", "ada@example.com")
      :ok = Team.add("eng@example.com", "engineer", "ada@example.com")
      branch = "n#{System.unique_integer([:positive])}"
      :ok = Branches.create(branch, "main", by: "eng@example.com")

      on_branch =
        String.replace(
          fixture("pricing.ex"),
          "div(subtotal * pct, 100)",
          "div(subtotal * min(pct, 50), 100)"
        )

      c = propose(branch: branch, unit_source: on_branch, proposer: by("eng@example.com"))
      # The engineer approves on their own branch: nobody else hears of it.
      before = seen()
      {:ok, _} = Changes.approve(c.id)
      assert notices(before) == []

      before = seen()
      live = propose(unit_source: cheaper_shipping_unit(), proposer: by("rev@example.com"))
      assert [m] = notices_soon(before)
      assert m.to == ["ada@example.com"]
      assert m.subject =~ "Waiting for you"
      assert m.text =~ "/changes/#{live.id}"

      before = seen()
      {:ok, _} = Changes.approve(live.id)
      # Branches other tests left open may hear of it too.
      assert [m] = notices_soon(before, &(&1.subject =~ "your branch #{branch} "))
      assert m.to == ["eng@example.com"]
    end

    test "list_changes filters by person" do
      {:ok, _} = Team.sign_in(%{email: "ada@example.com"})
      mine = propose(unit_source: cheaper_shipping_unit(), proposer: by("ada@example.com"))
      Team.act_as("ada@example.com")
      {:ok, text, _} = Theseus.MCP.Tools.call("list_changes", %{"mine" => true}, "t")
      assert text =~ mine.id

      {:ok, text, _} =
        Theseus.MCP.Tools.call("list_changes", %{"person" => "bob@example.com"}, "t")

      refute text =~ mine.id
    end
  end

  describe "the admin override" do
    test "an admin approves over an owner's rule with a reason, and the ledger says so" do
      ada = sign_in("ada@example.com")
      :ok = Team.add("own@example.com", "reviewer", "ada@example.com")
      :ok = Team.add("rev@example.com", "reviewer", "ada@example.com")
      :ok = Team.set_owners(Sample.Pricing, ["own@example.com"], "ada@example.com")

      c =
        propose(
          unit_source: cheaper_shipping_unit(),
          spec_source: cheaper_shipping_spec(),
          proposer: by("rev@example.com")
        )

      # A reviewer who is not an owner cannot override.
      rev = sign_in("rev@example.com")
      assert post("/changes/#{c.id}/approve", %{"override" => "please"}, rev).status == 403

      asked = post("/changes/#{c.id}/approve", %{}, ada)
      assert asked.status == 200, asked.resp_body
      assert asked.resp_body =~ "Not approved yet"
      assert asked.resp_body =~ "owned by own@example.com"
      assert {:ok, %{status: :held}, _} = Changes.get(c.id)

      done = post("/changes/#{c.id}/approve", %{"override" => "owner is away"}, ada)
      assert done.status == 303
      assert {:ok, %{status: :promoted}, _} = Changes.get(c.id)

      id = c.id
      events = Ledger.events()

      assert %{by: "ada@example.com"} =
               Enum.find(events, &match?(%{body: {:approval_override, ^id, "owner is away"}}, &1))

      assert %{by: "ada@example.com"} =
               Enum.find(events, &match?(%{body: {:gate_decision, ^id, :promote, :human}}, &1))
    end
  end
end
