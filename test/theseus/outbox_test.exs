defmodule Theseus.OutboxTest do
  @moduledoc "Messages the app sends: returned as data, checked, held or posted to a webhook."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Describe, Outbox, Report}

  defmodule Hook do
    @moduledoc false
    # A webhook that fails its first post and records the rest.
    use Plug.Router

    plug Plug.Parsers, parsers: [:json], json_decoder: JSON
    plug :match
    plug :dispatch

    post "/hook" do
      n = :persistent_term.get({__MODULE__, :posts}, 0) + 1
      :persistent_term.put({__MODULE__, :posts}, n)

      if n == 1 do
        send_resp(conn, 500, "not now")
      else
        :persistent_term.put(
          {__MODULE__, :last},
          {conn.body_params, get_req_header(conn, "authorization")}
        )

        send_resp(conn, 200, "ok")
      end
    end
  end

  setup do
    before = snapshot()
    on_exit(fn -> restore(before) end)
    :ok
  end

  defp message(fields \\ %{}),
    do: Map.merge(%{to: "ann@acme.com", subject: "Figma", text: "Bob asks for Figma."}, fields)

  test "messages are checked" do
    assert {:ok, %{to: ["ann@acme.com"], url: nil}} = Outbox.normalize(message())

    assert {:ok, %{url: url}} = Outbox.normalize(message(%{link: "/requests"}))
    assert url == Theseus.Web.public_url() <> "/requests"

    assert {:error, _} = Outbox.normalize(message(%{to: "not an address"}))
    assert {:error, _} = Outbox.normalize(message(%{to: []}))
    assert {:error, _} = Outbox.normalize(message(%{subject: ""}))
    assert {:error, _} = Outbox.normalize(message(%{text: nil}))
    assert {:error, _} = Outbox.normalize(message(%{link: "https://elsewhere.example/x"}))
    assert {:error, _} = Outbox.normalize(:hello)
  end

  test "lines, newlines and broken text are refused" do
    assert {:error, _} = Outbox.normalize(message(%{subject: "Hi\r\nBcc: x@y.co"}))
    assert {:error, _} = Outbox.normalize(message(%{to: "ann@acme.com\n"}))
    assert {:error, _} = Outbox.normalize(message(%{to: "Ann <ann@acme.com>"}))
    assert {:error, _} = Outbox.normalize(message(%{text: <<255, 254>>}))
    assert {:ok, _} = Outbox.normalize(message(%{text: "two\nlines"}))
  end

  test "messages around messages are all queued" do
    nested =
      {:send, [message(%{subject: "Outer"})],
       {:send, [message(%{subject: "Inner"})], {:redirect, "/x"}}}

    assert {:redirect, "/x"} = Outbox.take(nested, "test.nested")
    subjects = Enum.map(Outbox.list(5), & &1.subject)
    assert "Outer" in subjects and "Inner" in subjects
  end

  test "a result that sends is taken apart, and its messages are held by default" do
    assert {200, %{}} = Outbox.take({200, %{}}, "test")

    assert {:redirect, "/x"} =
             Outbox.take(
               {:send, [message(), message(%{to: "bad"})], {:redirect, "/x"}},
               "test.take"
             )

    [held | _] = Outbox.list(5)
    assert held.status == :held
    assert held.to == ["ann@acme.com"]
    assert held.source == "test.take"
  end

  test "an endpoint that sends: replay shows the messages, and the live call queues them" do
    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "POST", path: ["notify"]}),
            do: {:send, [%{to: "ann@acme.com", subject: "Hello", text: "Hi Ann", link: "/inbox"}], {200, %{sent: 1}}}

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    # A recorded call that the new route answers differently.
    request(:post, "/notify")

    {:ok, change, report} =
      Changes.check(
        proposal(
          unit: "Sample.Routes",
          unit_source: routes,
          intent: "notify",
          behaviour_change: true
        )
      )

    assert report.passed, inspect(Report.failure(report))
    d = Describe.change(change, report)
    row = Enum.find(d.behaviour.changed, &(&1.call =~ "notify"))
    assert row.after =~ ~s|sends 1 message (to ann@acme.com: "Hello"), then {200, %{sent: 1}}|

    # Nothing was queued by validation.
    refute Enum.any?(Outbox.list(50), &(&1.subject == "Hello"))

    approve_settled(
      unit: "Sample.Routes",
      unit_source: routes,
      intent: "notify",
      behaviour_change: true
    )

    assert {200, ~s({"sent":1})} = request(:post, "/notify")

    assert [%{subject: "Hello", url: url, source: source} | _] = Outbox.list(5)
    assert url =~ "/inbox"
    assert source == "Sample.Routes.handle POST /notify"

    # The outbox page shows it to a reviewer only.
    page = fn cookie ->
      conn = Plug.Test.conn(:get, "/outbox")
      conn = if cookie, do: Plug.Test.put_req_cookie(conn, "theseus_reviewer", cookie), else: conn
      conn = Theseus.Admin.Router.call(conn, [])
      {conn.status, conn.resp_body}
    end

    assert {403, refused} = page.(nil)
    refute refused =~ "Hi Ann"
    assert {200, html} = page.(Theseus.Review.token())
    assert html =~ "Hi Ann" and html =~ "held"
  end

  test "a message the outbox would refuse fails replay and shows why" do
    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "POST", path: ["notify"]}),
            do: {:send, [%{to: "Ann <ann@acme.com>", subject: "Hello", text: "Hi"}], {200, %{sent: 1}}}

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )

    request(:post, "/notify")

    {:ok, change, report} =
      Changes.check(
        proposal(
          unit: "Sample.Routes",
          unit_source: routes,
          intent: "notify",
          behaviour_change: true
        )
      )

    assert %{name: :replay, detail: %{reason: reason}} = Report.failure(report)
    assert reason =~ "the outbox refuses"
    d = Describe.change(change, report)
    row = Enum.find(d.behaviour.changed, &(&1.call =~ "notify"))
    assert row.after =~ "one the outbox refuses: to must be one or more email addresses"
  end

  test "a message that failed every attempt can be sent again" do
    :persistent_term.put({Hook, :posts}, 1)
    {:ok, pid} = Bandit.start_link(plug: Hook, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    on_exit(fn -> Application.delete_env(:theseus, :outbox) end)

    # Nothing listens on port 9 here, so every attempt fails.
    Application.put_env(:theseus, :outbox,
      adapter: :webhook,
      url: "http://127.0.0.1:9/hook",
      retry_ms: 1,
      max_retry_ms: 2
    )

    1 = Outbox.send_messages([message(%{subject: "Again"})], "test.again")

    failed =
      wait_for(fn ->
        Enum.find(Outbox.list(5), &(&1.subject == "Again" and &1.status == :failed))
      end)

    assert failed.attempts == 16

    Application.put_env(:theseus, :outbox,
      adapter: :webhook,
      url: "http://127.0.0.1:#{port}/hook"
    )

    :ok = Outbox.resend(failed.id)

    sent =
      wait_for(fn -> Enum.find(Outbox.list(5), &(&1.id == failed.id and &1.status == :sent)) end)

    assert sent.attempts == 1
  end

  defp wait_for(fun) do
    Enum.find_value(1..200, fn _ ->
      Process.sleep(20)
      fun.()
    end) || flunk("timed out")
  end

  test "the webhook gets each message, after a retry" do
    :persistent_term.put({Hook, :posts}, 0)
    {:ok, pid} = Bandit.start_link(plug: Hook, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    Application.put_env(:theseus, :outbox,
      adapter: :webhook,
      url: "http://127.0.0.1:#{port}/hook",
      token: "hook-token",
      retry_ms: 20
    )

    on_exit(fn -> Application.delete_env(:theseus, :outbox) end)

    1 = Outbox.send_messages([message(%{subject: "Webhook", link: "/requests"})], "test.webhook")

    sent =
      Enum.find_value(1..100, fn _ ->
        Process.sleep(20)
        Enum.find(Outbox.list(5), &(&1.subject == "Webhook" and &1.status == :sent))
      end)

    assert sent.attempts == 2
    {body, auth} = :persistent_term.get({Hook, :last})
    assert body["subject"] == "Webhook"
    assert body["to"] == ["ann@acme.com"]
    assert body["url"] =~ "/requests"
    assert auth == ["Bearer hook-token"]
  end

  defp request(method, path) do
    conn =
      Plug.Test.conn(method, path, "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Theseus.Web.call(Theseus.Web.init([]))

    {conn.status, conn.resp_body}
  end
end
