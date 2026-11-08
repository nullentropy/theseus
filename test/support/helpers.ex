defmodule Theseus.TestHelpers do
  @moduledoc false

  import Plug.Test
  import Plug.Conn

  @fixtures "test/fixtures/sample"

  def fixture(name), do: File.read!(Path.join(@fixtures, name))

  @doc "POSTs a JSON body to /price and returns `{status, decoded_body}`."
  def post_price(body) do
    conn =
      conn(:post, "/price", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Theseus.Web.call(Theseus.Web.init([]))

    {conn.status, JSON.decode!(conn.resp_body)}
  end

  @doc "Current version of every registered module."
  def snapshot, do: Map.new(Theseus.Registry.all(), &{&1.module, &1.current_version})

  @doc "Puts every module back on the version it had in `snapshot`."
  def restore(snapshot) do
    for {module, hash} <- snapshot, current(module) != hash do
      {:ok, _} = Theseus.Loader.rollback(module, hash, actor: :system, reason: "test cleanup")
    end

    :ok
  end

  def current(module), do: Theseus.Registry.fetch!(module).current_version

  @doc "Pricing with free shipping from 5000 cents."
  def cheaper_shipping_unit,
    do:
      String.replace(
        fixture("pricing.ex"),
        "@free_shipping_from 10_000",
        "@free_shipping_from 5_000"
      )

  @doc "The pricing spec updated for free shipping from 5000 cents."
  def cheaper_shipping_spec do
    fixture("pricing_spec.ex")
    |> String.replace("free when subtotal is 10000 or more", "free when subtotal is 5000 or more")
    |> String.replace(
      ~s(    example "free shipping at the threshold",),
      ~s"""
          example "free shipping from 5000",
            total: [[%{qty: 1, unit_cents: 5000}], nil],
            expect: %{subtotal_cents: 5000, discount_cents: 0, shipping_cents: 0, total_cents: 5000}

          example "free shipping at the threshold",
      """
      |> String.trim_trailing()
    )
  end

  @doc """
  The coupon store with a use count per code. Its state becomes
  `%{codes: MapSet, uses: map}`; code_change/3 migrates both ways.
  """
  def counting_coupon_store do
    fixture("coupon_store.ex")
    |> replace!(
      "  def init(codes), do: {:ok, MapSet.new(codes)}",
      "  def init(codes), do: {:ok, %{codes: MapSet.new(codes), uses: %{}}}"
    )
    |> replace!(
      "  def codes(store \\\\ __MODULE__), do: GenServer.call(store, :codes)",
      """
        def codes(store \\\\ __MODULE__), do: GenServer.call(store, :codes)
        def redeem(store \\\\ __MODULE__, code), do: GenServer.call(store, {:redeem, code})
        def uses(store \\\\ __MODULE__, code), do: GenServer.call(store, {:uses, code})
      """
      |> String.trim_trailing()
    )
    |> replace!(
      ~r/  @impl true\n  def handle_call.*?(?=  @impl true\n  def code_change)/s,
      """
        @impl true
        def handle_call({:active?, code}, _from, s), do: {:reply, MapSet.member?(s.codes, code), s}
        def handle_call({:activate, code}, _from, s), do: {:reply, :ok, %{s | codes: MapSet.put(s.codes, code)}}
        def handle_call({:deactivate, code}, _from, s), do: {:reply, :ok, %{s | codes: MapSet.delete(s.codes, code)}}
        def handle_call(:codes, _from, s), do: {:reply, s.codes |> MapSet.to_list() |> Enum.sort(), s}
        def handle_call({:redeem, code}, _from, s), do: {:reply, :ok, %{s | uses: Map.update(s.uses, code, 1, &(&1 + 1))}}
        def handle_call({:uses, code}, _from, s), do: {:reply, Map.get(s.uses, code, 0), s}

      """
    )
    |> replace!(
      "  def code_change(_old_vsn, codes, _extra), do: {:ok, codes}",
      """
        def code_change({:down, _vsn}, %{codes: codes}, _extra), do: {:ok, codes}
        def code_change(_old_vsn, %MapSet{} = codes, _extra), do: {:ok, %{codes: codes, uses: %{}}}
        def code_change(_old_vsn, state, _extra), do: {:ok, state}
      """
      |> String.trim_trailing()
    )
  end

  defp replace!(source, pattern, replacement) do
    if not (source =~ pattern), do: raise("pattern not found: #{inspect(pattern)}")
    String.replace(source, pattern, replacement)
  end

  @doc "Proposes a change, waits for its shadow run, checks it is held, approves it."
  def approve_settled(fields) do
    {:ok, change, _} = Theseus.Changes.propose(proposal(fields))
    {change, report} = settle(change.id)

    if change.status != :held,
      do:
        raise(
          "change #{change.id} is #{change.status}: #{inspect(Theseus.Report.failure(report))}"
        )

    {:ok, _} = Theseus.Changes.approve(change.id)
    {change, report}
  end

  @doc """
  Waits for a change's shadow run to end and returns `{change, report}`.
  `traffic`, if given, is called between checks to send live calls.
  """
  def settle(id, traffic \\ fn -> :ok end, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_settle(id, traffic, deadline)
  end

  defp do_settle(id, traffic, deadline) do
    case Theseus.Changes.get(id) do
      {:ok, %{status: :shadowing}, _} ->
        if System.monotonic_time(:millisecond) > deadline,
          do: raise("change #{id} is still shadowing")

        traffic.()
        Process.sleep(10)
        do_settle(id, traffic, deadline)

      {:ok, change, report} ->
        {change, report}
    end
  end

  def proposal(fields) do
    Map.merge(
      %{unit: "Sample.Pricing", intent: "test", proposer: %{kind: :test, client: "test"}},
      Map.new(fields)
    )
  end

  ## A scripted MCP client

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientInfo" => %{"name" => "test-client", "version" => "1.0"},
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  @doc "A 2026-07-28 request. Returns `{status, decoded_body}`."
  def modern(method, params \\ %{}, header_overrides \\ []) do
    params = Map.put(params, "_meta", @meta)

    headers =
      [{"mcp-protocol-version", "2026-07-28"}, {"mcp-method", method}] ++
        if(method == "tools/call", do: [{"mcp-name", params["name"]}], else: [])

    headers =
      Enum.reduce(header_overrides, headers, fn {k, v}, acc ->
        List.keystore(acc, k, 0, {k, v})
      end)

    mcp_post(
      %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      },
      headers
    )
  end

  @doc "Opens a legacy session with `initialize`. Returns the session id and the result."
  def legacy_initialize(client \\ "legacy-client") do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => client, "version" => "1"}
      }
    }

    conn = mcp_conn(body, [])
    {:ok, _} = {:ok, conn}
    [session] = get_resp_header(conn, "mcp-session-id")
    {session, JSON.decode!(conn.resp_body)}
  end

  @doc "A legacy request inside a session."
  def legacy(session, method, params \\ %{}) do
    mcp_post(
      %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      },
      [{"mcp-protocol-version", "2025-11-25"}, {"mcp-session-id", session}]
    )
  end

  def tool_text(%{"result" => %{"content" => [%{"text" => text} | _]}}), do: text

  def mcp_post(body, headers) do
    conn = mcp_conn(body, headers)
    {conn.status, if(conn.resp_body == "", do: nil, else: JSON.decode!(conn.resp_body))}
  end

  def mcp_conn(body, headers) do
    conn =
      conn(:post, "/mcp", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Theseus.Admin.Router.call(Theseus.Admin.Router.init([]))
  end
end
