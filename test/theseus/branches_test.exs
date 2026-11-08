defmodule Theseus.BranchesTest do
  @moduledoc "Phase 5 acceptance: branches, previews and merges."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Branches, Changes, Ledger, Loader, Previews, Report}

  @basket %{"items" => [%{"sku" => "b-1", "qty" => 3, "unit_cents" => 2000}]}

  setup do
    before = snapshot()

    on_exit(fn ->
      if Branches.live() != "main", do: :ok = Loader.switch("main")
      for p <- Previews.list(), do: Previews.stop(p.branch)
      restore(before)
    end)

    %{branch: "b#{System.unique_integer([:positive])}"}
  end

  defp propose_on(branch, fields) do
    {:ok, change, _} = Changes.propose(proposal([branch: branch] ++ fields))
    settle(change.id, fn -> post_price(@basket) end)
  end

  defp preview_price(url, body) do
    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(
        :post,
        {String.to_charlist(url <> "/price"), [], ~c"application/json", JSON.encode!(body)},
        [],
        body_format: :binary
      )

    {status, JSON.decode!(resp)}
  end

  test "fork, change on the branch, preview it, then merge into main with approval", %{branch: b} do
    main_before = Branches.current("main", Sample.Pricing)
    :ok = Branches.create(b)

    {change, report} =
      propose_on(b,
        intent: "make free shipping apply from 5000 cents",
        unit_source: cheaper_shipping_unit(),
        spec_source: cheaper_shipping_spec()
      )

    assert change.branch == b
    assert change.status == :held

    assert %{result: :skip, detail: %{reason: "the branch is not live"}} =
             Report.stage(report, :shadow)

    {:ok, _} = Changes.approve(change.id)

    # main is unchanged, and so is the running system.
    assert Branches.current("main", Sample.Pricing) == main_before
    assert current(Sample.Pricing) == main_before
    assert {200, %{"shipping_cents" => 599}} = post_price(@basket)
    refute Branches.current(b, Sample.Pricing) == main_before

    # The branch runs on its own node and port.
    {:ok, preview} = Previews.start(b)

    assert {200, %{"shipping_cents" => 0, "total_cents" => 6000}} =
             preview_price(preview.url, @basket)

    # Starting it again after another change on the branch restarts it on
    # the same URL with the change.
    assert {:ok, ^preview} = Previews.start(b)

    lower =
      String.replace(
        cheaper_shipping_unit(),
        "@free_shipping_from 5_000",
        "@free_shipping_from 4_000"
      )

    {more, more_report} = propose_on(b, intent: "free shipping from 4000", unit_source: lower)
    assert more.status == :held, inspect(Report.failure(more_report))
    {:ok, _} = Changes.approve(more.id)
    {:ok, again} = Previews.start(b)
    assert again.url == preview.url and again.started_at != preview.started_at
    basket = %{"items" => [%{"sku" => "x", "qty" => 1, "unit_cents" => 4500}]}
    assert {200, %{"shipping_cents" => 0}} = preview_price(again.url, basket)

    :ok = Previews.stop(b)

    assert [%{unit: Sample.Pricing, status: :from}] =
             Enum.reject(Branches.diff(b, "main"), &(&1.status == :same))

    {:ok, merge} = Branches.merge(b, "main")
    assert merge.conflicts == []
    assert [merge_change] = merge.changes
    assert merge_change.branch == "main"
    assert merge_change.trigger.kind == :merge

    {merge_change, _} = settle(merge_change.id, fn -> post_price(@basket) end)
    assert merge_change.status == :held
    {:ok, _} = Changes.approve(merge_change.id)

    assert {200, %{"shipping_cents" => 0}} = post_price(@basket)
    assert Branches.current("main", Sample.Pricing) == Branches.current(b, Sample.Pricing)
    assert Enum.all?(Branches.diff(b, "main"), &(&1.status == :same))

    history = Theseus.history(Sample.Pricing, 500)
    assert Enum.any?(history, &(&1.branch == b and &1.event =~ change.id))
    assert Enum.any?(history, &(&1.branch == "main" and &1.event =~ merge_change.id))
  end

  test "a unit changed differently on both sides is a conflict until a reconciled version is approved",
       %{branch: b} do
    :ok = Branches.create(b)

    on_branch =
      String.replace(fixture("pricing.ex"), "@shipping_cents 599", "@shipping_cents 599 + 0 * 1")

    {c1, _} =
      propose_on(b, intent: "tidy on the branch", unit_source: on_branch, behaviour_change: true)

    {:ok, _} = Changes.approve(c1.id)

    on_main =
      String.replace(fixture("pricing.ex"), "@shipping_cents 599", "@shipping_cents 599 + 0 * 2")

    {c2, _} =
      propose_on("main", intent: "tidy on main", unit_source: on_main, behaviour_change: true)

    {:ok, _} = Changes.approve(c2.id)

    {:ok, merge} = Branches.merge(b, "main")
    assert merge.changes == []
    assert merge.conflicts == [Sample.Pricing]

    reconciled =
      String.replace(fixture("pricing.ex"), "@shipping_cents 599", "@shipping_cents 599 + 0 * 3")

    {c3, _} =
      propose_on("main",
        intent: "reconcile both tidies",
        unit_source: reconciled,
        merge_from: b,
        behaviour_change: true
      )

    assert c3.trigger.kind == :merge
    {:ok, _} = Changes.approve(c3.id)

    # The reconciled change records the branch's version as merged, so
    # nothing is left to merge.
    assert %{status: :same} = Enum.find(Branches.diff(b, "main"), &(&1.unit == Sample.Pricing))
    {:ok, again} = Branches.merge(b, "main")
    assert again.changes == [] and again.conflicts == []
  end

  test "switching the live branch loads its versions, and switching back restores main", %{
    branch: b
  } do
    :ok = Branches.create(b)
    {change, _} = propose_on(b, intent: "cheaper", unit_source: cheaper_shipping_unit())
    {:ok, _} = Changes.approve(change.id)
    assert {200, %{"shipping_cents" => 599}} = post_price(@basket)

    :ok = Loader.switch(b)
    assert Branches.live() == b
    assert {200, %{"shipping_cents" => 0}} = post_price(@basket)

    :ok = Loader.switch("main")
    assert {200, %{"shipping_cents" => 599}} = post_price(@basket)

    switches = for %{body: {:branch_switched, to, from}} <- Ledger.events(), do: {from, to}
    assert {"main", b} in switches and {b, "main"} in switches
  end

  test "a unit created on a branch exists only there until the merge creates it on main", %{
    branch: b
  } do
    :ok = Branches.create(b)
    module = "Sample.Greeter#{System.unique_integer([:positive])}"

    unit = """
    defmodule #{module} do
      def hello(name), do: "Hello, " <> name <> "!"
    end
    """

    spec = """
    defmodule #{module}.Spec do
      use Theseus.Spec

      spec #{module} do
        prose "Greets a person by name."
        example "greets Ada", hello: ["Ada"], expect: "Hello, Ada!"
      end
    end
    """

    {created, _} =
      propose_on(b, unit: module, intent: "greet people", unit_source: unit, spec_source: spec)

    {:ok, _} = Changes.approve(created.id)
    atom = Module.concat([module])
    assert Branches.unit(b, atom)
    assert Branches.unit("main", atom) == nil
    assert Theseus.Registry.fetch(atom) == :error

    {:ok, %{changes: [merge_change]}} = Branches.merge(b, "main")
    assert merge_change.unit == atom
    {_, _} = settle(merge_change.id)
    {:ok, _} = Changes.approve(merge_change.id)
    assert Theseus.call(atom, :hello, ["Ada"]) == "Hello, Ada!"
  end

  test "a merge of several units is one group, approved together", %{branch: b} do
    :ok = Branches.create(b)

    pricing = String.replace(fixture("pricing.ex"), "def total(", "def price(")

    spec =
      fixture("pricing_spec.ex")
      |> String.replace(~r/\btotal: \[/, "price: [")
      |> String.replace("call.(:total,", "call.(:price,")

    routes =
      String.replace(
        fixture("routes.ex"),
        "Theseus.call(Sample.Pricing, :total, [request.items, rule])",
        "Theseus.call(Sample.Pricing, :price, [request.items, rule])"
      )

    {:ok, [{first, _}, _]} =
      Changes.propose_group(%{
        intent: "rename total to price",
        branch: b,
        proposer: %{kind: :test, client: "test"},
        units: [
          %{unit: "Sample.Pricing", unit_source: pricing, spec_source: spec},
          %{unit: "Sample.Routes", unit_source: routes}
        ]
      })

    {first, _} = settle(first.id)
    {:ok, _} = Changes.approve(first.id)

    {:ok, merge} = Branches.merge(b, "main")
    assert [c1, c2] = merge.changes
    assert c1.group != nil and c1.group == c2.group
    assert Enum.all?(merge.changes, &(&1.trigger.kind == :merge and &1.branch == "main"))

    for c <- merge.changes, do: settle(c.id, fn -> post_price(@basket) end)
    assert {:ok, _} = Changes.approve(c2.id)
    assert {200, %{"total_cents" => 6599}} = post_price(@basket)
    assert Enum.all?(Branches.diff(b, "main"), &(&1.status == :same))
  end

  test "a kept preview has no end and follows its branch", %{branch: b} do
    :ok = Branches.create(b)
    {:ok, preview} = Previews.start(b, keep: true)
    assert preview.stops_at == nil
    assert [%{branch: ^b, kept: true}] = Previews.list()
    assert {200, %{"shipping_cents" => 599}} = preview_price(preview.url, @basket)

    {change, _} = propose_on(b, intent: "cheaper shipping", unit_source: cheaper_shipping_unit())
    {:ok, _} = Changes.approve(change.id)

    # Without being asked, the preview starts again with the change, at the
    # same address.
    assert wait_for(fn ->
             match?([%{started_at: t}] when t != preview.started_at, Previews.list()) and
               match?({200, %{"shipping_cents" => 0}}, preview_price(preview.url, @basket))
           end)

    assert [%{url: url, kept: true}] = Previews.list()
    assert url == preview.url

    :ok = Previews.stop(b)
    assert Previews.list() == []
  end

  test "a kept preview starts again when the engine does", %{branch: b} do
    dir = Path.join(System.tmp_dir!(), "previews_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:theseus, :previews_file, true)
    Application.put_env(:theseus, :previews_path, Path.join(dir, "app.previews"))

    restart = fn ->
      :ok = Supervisor.terminate_child(Theseus.Supervisor, Theseus.Previews)
      {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, Theseus.Previews)
    end

    on_exit(fn ->
      Application.put_env(:theseus, :previews_file, false)
      Application.delete_env(:theseus, :previews_path)
      restart.()
      File.rm_rf(dir)
    end)

    restart.()
    :ok = Branches.create(b)
    {:ok, preview} = Previews.start(b, keep: true)
    restart.()
    assert wait_for(fn -> match?([%{branch: ^b, kept: true}], Previews.list()) end)
    assert [%{url: url}] = Previews.list()
    assert url == preview.url

    # Stopped, it stays stopped.
    :ok = Previews.stop(b)
    restart.()
    Process.sleep(300)
    assert Previews.list() == []
  end

  @tables """
  defmodule Sample.Tables do
    use Theseus.Schema

    def tables, do: %{notes: %{columns: %{text: :text}}}
  end
  """

  @seed """
  defmodule Sample.Seed do
    use Theseus.Seed

    def rows(_now), do: %{notes: [%{id: "n1", text: "hello"}, %{id: "n2", text: "world"}]}
  end
  """

  @tables_spec """
  defmodule Sample.Tables.Spec do
    use Theseus.Spec

    spec Sample.Tables do
      prose "The app's tables: notes, each with its text."
      example "notes", tables: [], expect: %{notes: %{columns: %{text: :text}}}
    end
  end
  """

  @seed_spec """
  defmodule Sample.Seed.Spec do
    use Theseus.Spec

    spec Sample.Seed do
      prose "Two made-up notes for previews."
      example "two notes", rows: [~U[2026-01-01 00:00:00Z]], expect: %{notes: [%{id: "n1", text: "hello"}, %{id: "n2", text: "world"}]}
    end
  end
  """

  @note_routes """
    def handle(%{method: "GET", path: ["notes"]}),
      do: {200, %{notes: Enum.map(Theseus.Store.all(:notes), & &1.text)}}

    def handle(%{method: "POST", path: ["notes"], body: body} = request),
      do: {:write, [{:insert, :notes, %{id: Theseus.Store.id(request), text: body["text"]}}], {201, %{}}}

    def handle(_request), do: {404, %{error: "not found"}}
  """

  defp notes_group(b, seed) do
    routes =
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}\n",
        @note_routes
      )

    %{
      intent: "keep notes",
      branch: b,
      proposer: %{kind: :test, client: "test"},
      units: [
        %{unit: "Sample.Tables", unit_source: @tables, spec_source: @tables_spec},
        %{unit: "Sample.Seed", unit_source: seed, spec_source: @seed_spec},
        %{unit: "Sample.Routes", unit_source: routes}
      ]
    }
  end

  defp preview_get(url) do
    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    {status, JSON.decode!(resp)}
  end

  test "a seed unit's rows must fit the branch's tables", %{branch: b} do
    :ok = Branches.create(b)
    bad = String.replace(@seed, ~s(text: "world"), ~s(body: "world"))
    bad_spec = String.replace(@seed_spec, ~s(text: "world"), ~s(body: "world"))
    group = notes_group(b, bad)

    group =
      update_in(group.units, fn units ->
        Enum.map(units, fn
          %{unit: "Sample.Seed"} = u -> %{u | spec_source: bad_spec}
          u -> u
        end)
      end)

    {:ok, results} = Changes.check_group(group)
    {_seed, report} = Enum.find(results, fn {c, _} -> c.unit == Sample.Seed end)
    assert %{name: :compile} = Report.failure(report)

    assert Theseus.Describe.change(
             elem(Enum.find(results, fn {c, _} -> c.unit == Sample.Seed end), 0),
             report
           ).stages
           |> Enum.flat_map(& &1.lines)
           |> Enum.any?(&(&1 =~ "its rows do not fit the tables" and &1 =~ "body"))

    {:ok, results} = Changes.check_group(notes_group(b, @seed))
    assert Enum.all?(results, fn {_c, r} -> Report.failure(r) == nil end)
  end

  test "a preview starts with the seed units' rows and keeps its writes in memory", %{branch: b} do
    :ok = Branches.create(b)
    {:ok, [{first, _} | _] = results} = Changes.propose_group(notes_group(b, @seed))
    for {c, _} <- results, do: settle(c.id)
    {:ok, _} = Changes.approve(first.id)

    {:ok, preview} = Previews.start(b)
    assert preview.data == :made_up
    assert {200, %{"notes" => ["hello", "world"]}} = preview_get(preview.url <> "/notes")

    {:ok, {{_, 201, _}, _, _}} =
      :httpc.request(
        :post,
        {String.to_charlist(preview.url <> "/notes"), [], ~c"application/json",
         JSON.encode!(%{"text" => "from the preview"})},
        [],
        body_format: :binary
      )

    assert {200, %{"notes" => notes}} = preview_get(preview.url <> "/notes")
    assert "from the preview" in notes and length(notes) == 3
  end

  test "at the cap, starting a preview stops the one used longest ago", %{branch: b} do
    previews = Application.get_env(:theseus, :previews, [])
    Application.put_env(:theseus, :previews, Keyword.put(previews, :max, 1))
    on_exit(fn -> Application.put_env(:theseus, :previews, previews) end)

    other = b <> "x"
    :ok = Branches.create(b)
    :ok = Branches.create(other)
    {:ok, _} = Previews.start(b, keep: true)
    {:ok, _} = Previews.start(other)
    assert [%{branch: ^other}] = Previews.list()
  end

  defp wait_for(fun, tries \\ 150) do
    cond do
      safely(fun) -> true
      tries == 0 -> false
      true -> Process.sleep(100) && wait_for(fun, tries - 1)
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  test "a branch has an owner and a description, and a closed one takes no changes", %{
    branch: b
  } do
    long = String.duplicate("x", 201)
    assert {:error, _} = Branches.create(b, "main", description: long)
    refute Branches.exists?(b)

    :ok = Branches.create(b, "main", by: "ann@example.com", description: "cheaper shipping")

    assert %{owner: "ann@example.com", description: "cheaper shipping", closed: false} =
             Enum.find(Branches.list(), &(&1.name == b))

    :ok = Branches.describe(b, "cheaper shipping for big baskets")
    assert Branches.description(b) == "cheaper shipping for big baskets"

    {:ok, _} = Previews.start(b)
    assert {:error, "main stays open"} = Branches.close("main")
    assert :ok = Branches.close(b, by: "ann@example.com")
    assert Branches.closed?(b)
    assert Previews.list() == []

    assert {:error, why} =
             Changes.propose(proposal(branch: b, unit_source: cheaper_shipping_unit()))

    assert why =~ "is closed"
    assert {:error, _} = Loader.switch(b)

    assert [%{waiting_changes: 0, closed: true, owner: "ann@example.com"}] =
             for(
               x <-
                 Theseus.MCP.Tools.call("list_branches", %{}, "t")
                 |> elem(2)
                 |> Map.get(:branches),
               x.name == b,
               do: x
             )

    assert :ok = Branches.reopen(b)
    refute Branches.closed?(b)
    {_c, _} = propose_on(b, unit_source: cheaper_shipping_unit())
    assert %{open_changes: 1} = Enum.find(Theseus.branches(), &(&1.name == b))
  end

  test "branch names are checked and forks need an existing parent" do
    assert {:error, _} = Branches.create("Not Valid")
    assert {:error, _} = Branches.create("orphan", "no-such-branch")
    assert {:error, _} = Branches.create("main")
  end
end
