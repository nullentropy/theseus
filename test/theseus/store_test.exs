defmodule Theseus.StoreTest do
  @moduledoc "The app's data: queries as data, writes returned as data, one transaction per call."

  use ExUnit.Case, async: false

  import Theseus.TestHelpers

  alias Theseus.{Changes, Loader, Report, Store, Version}

  @rows [
    %{id: "a", text: "apple", n: 3, tag: "fruit", at: ~U[2026-10-01 09:00:00Z]},
    %{id: "b", text: "Banana", n: 1, tag: nil, at: ~U[2026-10-02 09:00:00Z]},
    %{id: "c", text: "cherry", n: 2, tag: "fruit", at: ~U[2026-10-03 09:00:00Z]},
    %{id: "d", text: "date", n: 2, tag: "dried", at: ~U[2026-10-04 09:00:00Z]}
  ]

  @queries [
    [],
    [where: [tag: "fruit"]],
    [where: [tag: nil]],
    [where: [tag: {:not, nil}], order: [desc: :n]],
    [where: [n: {:in, [1, 2]}]],
    [where: [n: {:>=, 2}, tag: {:!=, "dried"}]],
    [where: [at: {:<, ~U[2026-10-03 09:00:00Z]}]],
    [where: [text: {:>, "b"}]],
    [order: [asc: :tag]],
    [order: [desc: :tag, asc: :text]],
    [order: [:text], limit: 2, offset: 1],
    [where: [n: {:in, []}]]
  ]

  describe "in memory" do
    test "reads filter as SQL does and always come back in the same order" do
      Store.with_rows(%{notes: @rows}, fn ->
        ids = fn opts -> Enum.map(Store.all(:notes, opts), & &1.id) end

        assert ids.([]) == ~w(a b c d)
        assert ids.(where: [tag: "fruit"]) == ~w(a c)
        # A comparison with nothing is never true; only nil checks find it.
        assert ids.(where: [tag: nil]) == ~w(b)
        assert ids.(where: [tag: {:!=, "fruit"}]) == ~w(d)
        assert ids.(where: [n: {:in, [1, 2]}]) == ~w(b c d)
        # Ties are broken by id; text compares by bytes, so capitals first.
        assert ids.(order: [desc: :n]) == ~w(a c d b)
        assert ids.(order: [:text]) == ~w(b a c d)
        # Empty values go last going up and first going down, as in Postgres.
        assert ids.(order: [asc: :tag]) == ~w(d a c b)
        assert ids.(order: [desc: :tag]) == ~w(b a c d)
        assert ids.(limit: 2, offset: 1) == ~w(b c)
        assert Store.count(:notes, where: [tag: "fruit"]) == 2
        assert Store.get(:notes, "c").text == "cherry"
        assert Store.get(:notes, "z") == nil
        assert Store.get(:notes, nil) == nil
        assert Store.all(:other) == []
      end)
    end

    test "times come back to the microsecond, maps with string keys" do
      Store.with_rows(%{notes: [%{id: "a", at: ~U[2026-10-01 09:00:00Z], data: %{k: 1}}]}, fn ->
        assert [%{at: at, data: data}] = Store.all(:notes)
        assert at.microsecond == {0, 6}
        assert data == %{"k" => 1}
      end)
    end

    test "a query that is not valid says why" do
      Store.with_rows(%{}, fn ->
        for {fun, why} <- [
              {fn -> apply(Store, :all, ["notes"]) end, "named with an atom"},
              {fn -> Store.all(:notes, sort: [:id]) end,
               "where:, join:, search:, order:, limit: and offset:"},
              {fn -> Store.all(:notes, where: [n: %{}]) end, "compares with text"},
              {fn -> Store.all(:notes, order: [up: :n]) end, "asc: column or desc: column"},
              {fn -> Store.all(:notes, limit: 0) end, "limit: is from 1"}
            ] do
          assert_raise ArgumentError, ~r/#{why}/, fun
        end
      end)
    end

    test "outside a request, tick, sync or sign-in there is no store" do
      assert_raise ArgumentError, ~r/only available while the engine runs/, fn ->
        Store.all(:notes)
      end
    end
  end

  test "writes are taken from around a result, through messages and htmx headers" do
    insert = {:insert, :notes, %{id: "x", text: "hi"}}
    update = {:update, :notes, "y", %{text: "yo"}, if: [text: "hey"]}

    assert Store.take_writes(
             {:send, [:m], {:write, [insert], {:htmx, %{}, {:write, [update], :ok}}}}
           ) ==
             {[insert, update], {:send, [:m], {:htmx, %{}, :ok}}}

    assert Store.check_writes([insert, update, {:delete, :notes, "z"}]) == :ok
    assert {:error, why} = Store.check_writes([{:insert, :notes, %{text: "no id"}}])
    assert why =~ "with the row's id"
    assert {:error, _} = Store.check_writes([{:update, :notes, "y", %{id: "z"}}])
    assert {:error, _} = Store.check_writes([{:drop, :notes}])
  end

  test "new ids come from the request's id, so a replayed call makes the same ones" do
    request = %{id: "abc", now: ~U[2026-10-01 09:00:00Z]}
    assert Store.id(request, 1) == Store.id(request, 1)
    assert Store.id(request, 1) != Store.id(request, 2)
    assert Store.id(request) =~ ~r/^[a-z2-7]{20}$/
    # An old recorded call without an id still gets the same ids every time.
    assert Store.id(%{now: request.now}) == Store.id(%{now: request.now})
  end

  describe "in Postgres" do
    @describetag :postgres

    @schema """
    defmodule Sample.NotesSchema do
      use Theseus.Schema

      def tables do
        %{notes: %{columns: %{text: :text, n: :integer, tag: {:text, null: true}, at: :utc_datetime}, indexes: [[:tag]]}}
      end
    end
    """

    @schema_spec """
    defmodule Sample.NotesSchema.Spec do
      use Theseus.Spec

      spec Sample.NotesSchema, deterministic: true do
        prose "The notes table: each note has text, a number, maybe a tag, and a time."

        invariant "Notes have text.",
          check: fn call -> Map.has_key?(call.(:tables, []).notes.columns, :text) end
      end
    end
    """

    setup do
      before = snapshot()
      {:ok, spec} = Version.build(Sample.NotesSchema.Spec, @schema_spec)
      {:ok, _} = Loader.register(spec, kind: :spec, actor: :system)
      {:ok, schema} = Version.build(Sample.NotesSchema, @schema)
      {:ok, _} = Loader.register(schema, kind: :pure, actor: :system)

      on_exit(fn ->
        Loader.unregister(Sample.NotesSchema, actor: :system)
        Loader.unregister(Sample.NotesSchema.Spec, actor: :system)
        restore(before)
        Postgrex.query!(Theseus.Store.Pool, ~s(DROP TABLE IF EXISTS "theseus_test"."notes"), [])
      end)

      :ok
    end

    defp write!(ops), do: :ok = Store.run("test", fn -> {:write, ops, :ok} end)
    defp read(fun), do: Store.run("test", fun)

    test "registering a schema unit creates its tables, and reads match the in-memory store" do
      write!(for row <- @rows, do: {:insert, :notes, row})

      for query <- @queries do
        in_postgres = read(fn -> Store.all(:notes, query) end)
        in_memory = Store.with_rows(%{notes: @rows}, fn -> Store.all(:notes, query) end)
        assert in_postgres == in_memory, "query #{inspect(query)}"
      end

      assert read(fn -> Store.count(:notes, where: [tag: "fruit"]) end) == 2
      assert read(fn -> Store.get(:notes, "b") end).tag == nil
    end

    @tags_schema """
    defmodule Sample.TagsSchema do
      use Theseus.Schema

      def tables do
        %{tags: %{columns: %{label: :text, rank: {:integer, null: true}, parent: {:text, null: true}}}}
      end
    end
    """

    test "joins, figures and text search give the same rows in Postgres as in memory" do
      {:ok, tags} = Version.build(Sample.TagsSchema, @tags_schema)
      {:ok, _} = Loader.register(tags, kind: :pure, actor: :system)

      on_exit(fn ->
        Loader.unregister(Sample.TagsSchema, actor: :system)
        Postgrex.query!(Theseus.Store.Pool, ~s(DROP TABLE IF EXISTS "theseus_test"."tags"), [])
      end)

      more = [
        %{id: "e", text: "Éclair", n: 5, tag: "baked", at: ~U[2026-10-05 09:00:00Z]},
        %{id: "f", text: "FIG jam", n: 4, tag: "fruit", at: ~U[2026-10-06 09:00:00Z]}
      ]

      tag_rows = [
        %{id: "fruit", label: "Fruit", rank: 2, parent: "food"},
        %{id: "dried", label: "Dried", rank: nil, parent: "fruit"},
        %{id: "food", label: "Food", rank: 1, parent: nil}
      ]

      notes = @rows ++ more

      write!(
        for(row <- notes, do: {:insert, :notes, row}) ++
          for(row <- tag_rows, do: {:insert, :tags, row})
      )

      memory = fn fun -> Store.with_rows(%{notes: notes, tags: tag_rows}, fun) end
      same = fn fun -> assert read(fun) == memory.(fun), inspect(fun) end

      join = [kind: {:tags, :tag}]
      deep = [kind: {:tags, :tag}, parent: {:tags, {:kind, :parent}}]

      for query <- [
            [join: join],
            [join: join, where: [kind: [label: "Fruit"]]],
            [join: join, where: [kind: [rank: nil]]],
            [join: join, where: [kind: [rank: {:>, 1}], n: {:<, 4}]],
            [join: join, order: [desc: {:kind, :rank}, asc: :text]],
            [join: join, order: [asc: {:kind, :label}], limit: 3],
            [where: [text: {:contains, "an"}]],
            [where: [text: {:contains, "AN"}]],
            [where: [text: {:icontains, "AN"}]],
            [where: [text: {:icontains, "fig"}]],
            # Only ASCII letters change case: É and é stay apart.
            [where: [text: {:icontains, "é"}]],
            [where: [text: {:icontains, "ÉC"}]],
            # A join from an earlier join.
            [join: deep],
            [join: deep, where: [parent: [label: "Food"]]],
            [join: deep, order: [asc: {:parent, :label}, desc: :n]],
            # Words, ranked by how often they appear.
            [search: {:text, "a"}],
            [search: {:text, "AN"}, limit: 2],
            [search: {[:text, :tag], "fruit a"}],
            [search: {[:text, {:kind, :label}], "fr"}, join: join],
            [search: {:text, "nothing"}],
            [search: {:text, "   "}]
          ] do
        same.(fn -> Store.all(:notes, query) end)
      end

      assert [%{kind: %{label: "Fruit"}}, %{kind: nil}, %{kind: %{label: "Fruit"}} | _] =
               read(fn -> Store.all(:notes, join: join) end)

      same.(fn -> Store.count(:notes, join: join, where: [kind: [label: {:not, nil}]]) end)

      for opts <- [
            [compute: [n: :count, total: {:sum, :n}, first: {:min, :at}, last: {:max, :text}]],
            [compute: [n: :count, total: {:sum, :n}], where: [n: {:>, 100}]],
            [by: [:tag], compute: [n: :count, tagged: {:count, :tag}, total: {:sum, :n}]],
            [by: [:tag], compute: [n: :count], order: [desc: :n], limit: 2],
            [by: [:tag, :n], compute: [first: {:min, :text}], where: [n: {:<=, 3}]],
            # Figures over joined rows.
            [
              join: join,
              by: [label: {:kind, :label}],
              compute: [n: :count, top: {:max, {:kind, :rank}}]
            ],
            [
              join: deep,
              by: [:tag, up: {:parent, :label}],
              compute: [n: {:sum, :n}],
              order: [desc: :n]
            ],
            [
              join: join,
              compute: [ranked: {:count, {:kind, :rank}}],
              where: [kind: [label: {:not, nil}]]
            ]
          ] do
        same.(fn -> Store.aggregate(:notes, opts) end)
      end

      assert %{n: 6, total: 17} =
               read(fn -> Store.aggregate(:notes, compute: [n: :count, total: {:sum, :n}]) end)

      assert %{n: 0, total: 0, low: nil} =
               read(fn ->
                 Store.aggregate(:notes,
                   compute: [n: :count, total: {:sum, :n}, low: {:min, :n}],
                   where: [n: 0]
                 )
               end)

      assert [%{tag: "fruit", n: 3} | _] =
               read(fn ->
                 Store.aggregate(:notes, by: [:tag], compute: [n: :count], order: [desc: :n])
               end)

      assert_raise ArgumentError, ~r/is not an integer column/, fn ->
        read(fn -> Store.aggregate(:notes, compute: [t: {:sum, :text}]) end)
      end

      assert_raise ArgumentError, ~r/not a text column/, fn ->
        read(fn -> Store.all(:notes, join: [x: {:tags, :n}]) end)
      end

      assert [%{id: "b", text: "Banana"} | _] =
               read(fn -> Store.all(:notes, search: {:text, "a"}) end)

      assert [%{parent: %{label: "Food"}} | _] =
               read(fn -> Store.all(:notes, join: deep, where: [id: "a"]) end)

      assert_raise ArgumentError, ~r/must be joined before/, fn ->
        read(fn -> Store.all(:notes, join: [p: {:tags, {:k, :parent}}, k: {:tags, :tag}]) end)
      end
    end

    test "an update whose row changed meanwhile runs the call again, on the new data" do
      write!([{:insert, :notes, %{id: "a", text: "apple", n: 1, at: ~U[2026-10-01 09:00:00Z]}}])
      attempts = :counters.new(1, [])

      result =
        Store.run("test", fn ->
          :counters.add(attempts, 1, 1)
          %{n: n} = Store.get(:notes, "a")

          # Someone else adds one between this call's read and its write.
          if :counters.get(attempts, 1) == 1,
            do: Task.await(Task.async(fn -> write!([{:update, :notes, "a", %{n: n + 1}}]) end))

          {:write, [{:update, :notes, "a", %{n: n + 10}, if: [n: n]}], n}
        end)

      assert result == 2
      assert :counters.get(attempts, 1) == 2
      assert read(fn -> Store.get(:notes, "a") end).n == 12
    end

    test "a call that touched a server unit is not run again" do
      write!([{:insert, :notes, %{id: "a", text: "apple", n: 1, at: ~U[2026-10-01 09:00:00Z]}}])

      result =
        Store.run(
          "test",
          fn ->
            Store.server_called()
            {:write, [{:update, :notes, "a", %{n: 5}, if: [n: 99]}], :done}
          end,
          :not_saved
        )

      assert result == :not_saved
      assert read(fn -> Store.get(:notes, "a") end).n == 1
    end

    test "writes the tables refuse roll everything back" do
      for {ops, why} <- [
            {[{:insert, :notes, %{id: "a", text: "x", at: ~U[2026-10-01 09:00:00Z]}}], "needs n"},
            {[{:insert, :notes, %{id: "a", text: 1, n: 1, at: ~U[2026-10-01 09:00:00Z]}}],
             "holds text"},
            {[{:insert, :other, %{id: "a"}}], "no table :other"},
            {[{:update, :notes, "a", %{color: "red"}}], "no column :color"}
          ] do
        assert_raise ArgumentError, ~r/#{why}/, fn -> write!(ops) end
      end

      row = %{id: "a", text: "x", n: 1, at: ~U[2026-10-01 09:00:00Z]}
      write!([{:insert, :notes, row}])

      # A taken id is a conflict: the call runs again, then gives up.
      assert Store.run(
               "test",
               fn -> {:write, [{:insert, :notes, %{row | text: "y"}}], :ok} end,
               :not_saved
             ) ==
               :not_saved

      assert read(fn -> Store.get(:notes, "a") end).text == "x"
    end

    test "a preview reads the data and keeps none of its writes" do
      config = Application.get_env(:theseus, :store)
      Application.put_env(:theseus, :store, Keyword.put(config, :preview, true))
      on_exit(fn -> Application.put_env(:theseus, :store, config) end)

      assert Store.run("test", fn ->
               {:write,
                [{:insert, :notes, %{id: "p", text: "p", n: 1, at: ~U[2026-10-01 09:00:00Z]}}],
                :shown}
             end) ==
               :shown

      Application.put_env(:theseus, :store, config)
      assert read(fn -> Store.get(:notes, "p") end) == nil
    end

    test "a preview of live data sees its branch's tables and keeps none of them" do
      config = Application.get_env(:theseus, :store)
      live = Theseus.Store.DB.tables()

      {:ok, branch} =
        Theseus.Schema.normalize(%{
          notes: %{
            columns: %{text: :text, tag: {:text, null: true}, at: :utc_datetime, mood: :text}
          },
          moods: %{columns: %{name: :text}}
        })

      Application.put_env(:theseus, :store, Keyword.put(config, :preview, true))
      :persistent_term.put({Theseus.Store.DB, :tables}, branch)
      :persistent_term.erase({Theseus.Store.DB, :preview_differing})

      on_exit(fn ->
        Application.put_env(:theseus, :store, config)
        :persistent_term.put({Theseus.Store.DB, :tables}, live)
        :persistent_term.erase({Theseus.Store.DB, :preview_differing})
      end)

      seen =
        Store.run("test", fn ->
          {:write,
           [
             {:insert, :notes, %{id: "p", text: "p", mood: "calm", at: ~U[2026-10-01 09:00:00Z]}},
             {:insert, :moods, %{id: "m", name: "calm"}}
           ], :written}
        end)

      assert seen == :written
      assert Store.run("test", fn -> Store.all(:notes) end) == []

      Application.put_env(:theseus, :store, config)
      :persistent_term.put({Theseus.Store.DB, :tables}, live)
      assert read(fn -> Store.get(:notes, "p") end) == nil
      assert Map.has_key?(columns(), "n") and not Map.has_key?(columns(), "mood")
    end

    defp notes_routes do
      String.replace(
        fixture("routes.ex"),
        "  def handle(_request), do: {404, %{error: \"not found\"}}",
        """
          def handle(%{method: "POST", path: ["notes"], body: %{"text" => text}} = r) do
            row = %{id: Theseus.Store.id(r), text: text, n: 0, at: r.now}
            {:write, [{:insert, :notes, row}], {201, %{id: row.id}}}
          end

          def handle(%{method: "GET", path: ["notes"]}) do
            {200, %{notes: Enum.map(Theseus.Store.all(:notes, order: [:text]), & &1.text)}}
          end

          def handle(_request), do: {404, %{error: "not found"}}
        """
        |> String.trim_trailing()
      )
    end

    test "an endpoint unit reads and writes over HTTP, and its changes validate" do
      routes = notes_routes()

      _ =
        String.replace(
          fixture("routes.ex"),
          "  def handle(_request), do: {404, %{error: \"not found\"}}",
          """
            def handle(%{method: "POST", path: ["notes"], body: %{"text" => text}} = r) do
              row = %{id: Theseus.Store.id(r), text: text, n: 0, at: r.now}
              {:write, [{:insert, :notes, row}], {201, %{id: row.id}}}
            end

            def handle(%{method: "GET", path: ["notes"]}) do
              {200, %{notes: Enum.map(Theseus.Store.all(:notes, order: [:text]), & &1.text)}}
            end

            def handle(_request), do: {404, %{error: "not found"}}
          """
          |> String.trim_trailing()
        )

      {:ok, _change, report} =
        Changes.check(
          proposal(
            unit: "Sample.Routes",
            unit_source: routes,
            intent: "notes",
            behaviour_change: true
          )
        )

      assert report.passed, inspect(Report.failure(report))

      {:ok, version} = Version.build(Sample.Routes, routes, current(Sample.Routes))
      {:ok, _} = Loader.promote(version, actor: :system)

      http = fn method, path, body ->
        conn =
          Plug.Test.conn(method, path, body && JSON.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Theseus.Web.call(Theseus.Web.init([]))

        {conn.status, JSON.decode!(conn.resp_body)}
      end

      assert {201, %{"id" => _}} = http.(:post, "/notes", %{"text" => "pear"})
      assert {201, _} = http.(:post, "/notes", %{"text" => "fig"})
      assert {200, %{"notes" => ["fig", "pear"]}} = http.(:get, "/notes", nil)
    end

    test "a spec rule sees the writes of its earlier calls" do
      routes = notes_routes()

      rule = """
          invariant "a note added is listed",
            check: fn call ->
              req = fn method, path, body ->
                %{method: method, path: path, query: %{}, body: body, user: nil, csrf_token: nil, now: ~U[2026-10-13 12:00:00Z], id: "req-" <> Enum.join(path)}
              end

              {:write, _, {201, _}} = call.(:handle, [req.("POST", ["notes"], %{"text" => "pear"})])
              {200, %{notes: ["pear"]}} = call.(:handle, [req.("GET", ["notes"], %{})])
              true
            end
      """

      spec =
        String.replace(
          fixture("routes_spec.ex"),
          ~r/\n  end\nend\n$/,
          "\n" <> rule <> "  end\nend\n"
        )

      assert spec =~ "a note added is listed"

      {:ok, _change, report} =
        Changes.check(
          proposal(
            unit: "Sample.Routes",
            unit_source: routes,
            spec_source: spec,
            intent: "notes",
            behaviour_change: true
          )
        )

      assert report.passed, inspect(Report.failure(report))
      assert %{result: :pass, detail: %{count: count}} = Report.stage(report, :invariants)
      assert count >= 1
    end

    test "replay runs recorded calls on the app's data, and keeps none of their writes" do
      {:ok, version} = Version.build(Sample.Routes, notes_routes(), current(Sample.Routes))
      {:ok, _} = Loader.promote(version, actor: :system)
      Theseus.Traces.clear(Sample.Routes)

      write!([
        {:insert, :notes, %{id: "a", text: "apple", n: 1, at: ~U[2026-10-01 09:00:00Z]}},
        {:insert, :notes, %{id: "b", text: "banana", n: 2, at: ~U[2026-10-02 09:00:00Z]}}
      ])

      http = fn method, path, body ->
        conn =
          Plug.Test.conn(method, path, body && JSON.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Theseus.Web.call(Theseus.Web.init([]))

        {conn.status, JSON.decode!(conn.resp_body)}
      end

      assert {200, %{"notes" => ["apple", "banana"]}} = http.(:get, "/notes", nil)
      assert {201, _} = http.(:post, "/notes", %{"text" => "cherry"})
      assert {200, %{"notes" => ["apple", "banana", "cherry"]}} = http.(:get, "/notes", nil)
      assert read(fn -> Store.count(:notes) end) == 3

      # The proposed version lists one note. The difference only shows with data.
      fewer =
        String.replace(
          notes_routes(),
          "Theseus.Store.all(:notes, order: [:text])",
          "Theseus.Store.all(:notes, order: [:text], limit: 1)"
        )

      assert fewer != notes_routes()

      {:ok, change, report} =
        Changes.check(
          proposal(
            unit: "Sample.Routes",
            unit_source: fewer,
            intent: "one note",
            behaviour_change: true
          )
        )

      assert report.passed, inspect(Report.failure(report))

      assert %{result: :info, detail: %{compared: 3, differ: 2, data: :snapshot}} =
               Report.stage(report, :replay)

      %{detail: %{traces: traces}} = Report.stage(report, :behaviour)
      befores = for %{before: {:ok, {200, %{notes: notes}}}} <- traces.changed, do: notes
      afters = for %{after: {:ok, {200, %{notes: notes}}}} <- traces.changed, do: notes
      # Both recorded GETs read the data as it is now, not as it was when recorded.
      assert befores == [["apple", "banana", "cherry"], ["apple", "banana", "cherry"]]
      assert afters == [["apple"], ["apple"]]

      # The replayed insert went into the snapshot's transaction, not the table.
      assert read(fn -> Store.count(:notes) end) == 3

      assert Theseus.Describe.change(change, report).stages
             |> Enum.find(&(&1.name == "replay"))
             |> Map.get(:lines)
             |> hd() =~ "on the app's data"
    end

    test "replay on another branch runs on the app's data with that branch's tables" do
      {:ok, version} = Version.build(Sample.Routes, notes_routes(), current(Sample.Routes))
      {:ok, _} = Loader.promote(version, actor: :system)
      Theseus.Traces.clear(Sample.Routes)

      write!([
        {:insert, :notes, %{id: "a", text: "apple", n: 1, at: ~U[2026-10-01 09:00:00Z]}},
        {:insert, :notes, %{id: "b", text: "banana", n: 2, at: ~U[2026-10-02 09:00:00Z]}}
      ])

      conn =
        Plug.Test.conn(:get, "/notes")
        |> Theseus.Web.call(Theseus.Web.init([]))

      assert conn.status == 200

      branch = "moods#{System.unique_integer([:positive])}"
      :ok = Theseus.Branches.create(branch)

      with_mood =
        String.replace(
          @schema,
          "at: :utc_datetime}",
          "at: :utc_datetime, mood: {:text, null: true}}"
        )

      assert with_mood != @schema

      {:ok, schema_change, _} =
        Changes.propose(
          proposal(
            unit: "Sample.NotesSchema",
            unit_source: with_mood,
            branch: branch,
            intent: "notes have a mood"
          )
        )

      {:ok, _} = Changes.approve(schema_change.id)

      # The branch's version reads a column only the branch has.
      calm =
        String.replace(
          notes_routes(),
          "Theseus.Store.all(:notes, order: [:text])",
          "Theseus.Store.all(:notes, where: [mood: \"calm\"], order: [:text])"
        )

      {:ok, _change, report} =
        Changes.check(
          proposal(
            unit: "Sample.Routes",
            unit_source: calm,
            branch: branch,
            intent: "calm notes",
            behaviour_change: true
          )
        )

      assert report.passed, inspect(Report.failure(report))

      assert %{result: :info, detail: %{compared: 1, differ: 1, data: :snapshot}} =
               Report.stage(report, :replay)

      %{detail: %{traces: %{changed: [changed]}}} = Report.stage(report, :behaviour)
      assert {:ok, {200, %{notes: ["apple", "banana"]}}} = changed.before
      assert {:ok, {200, %{notes: []}}} = changed.after

      # The branch's column went with the rollback.
      refute Map.has_key?(columns(), "mood")
    end

    @notes_unit """
    defmodule Sample.Notes do
      use Theseus.Endpoint

      def handle(%{method: "POST", path: ["notes"], body: %{"text" => text}} = r) do
        row = %{id: Theseus.Store.id(r), text: text, n: 0, at: r.now}
        {:write, [{:insert, :notes, row}], {201, %{id: row.id}}}
      end

      def handle(%{method: "GET", path: ["notes"]}) do
        {200, %{notes: Enum.map(Theseus.Store.all(:notes, order: [:text]), & &1.text)}}
      end

      def handle(_request), do: {404, %{error: "not found"}}
    end
    """

    @notes_spec """
    defmodule Sample.Notes.Spec do
      use Theseus.Spec

      spec Sample.Notes, deterministic: true do
        prose "Lists notes and records new ones."

        invariant "Other paths are not found.",
          check: fn call -> match?({404, _}, call.(:handle, [%{method: "GET", path: ["x"]}])) end
      end
    end
    """

    test "a shadow run of an endpoint unit reads what each live request read, and writes nothing" do
      {:ok, spec} = Version.build(Sample.Notes.Spec, @notes_spec)
      {:ok, _} = Loader.register(spec, kind: :spec, actor: :system)
      {:ok, notes} = Version.build(Sample.Notes, @notes_unit)
      {:ok, _} = Loader.register(notes, kind: :endpoint, actor: :system)

      on_exit(fn ->
        Loader.unregister(Sample.Notes, actor: :system)
        Loader.unregister(Sample.Notes.Spec, actor: :system)
      end)

      # The root hands /notes to Sample.Notes, which calls no other unit.
      promote_routes(
        String.replace(
          fixture("routes.ex"),
          "  def handle(_request), do: {404, %{error: \"not found\"}}",
          "  def handle(%{path: [\"notes\"]} = r), do: Theseus.call(Sample.Notes, :handle, [r])\n\n  def handle(_request), do: {404, %{error: \"not found\"}}"
        )
      )

      write!([
        {:insert, :notes, %{id: "a", text: "apple", n: 1, at: ~U[2026-10-01 09:00:00Z]}},
        {:insert, :notes, %{id: "b", text: "banana", n: 2, at: ~U[2026-10-02 09:00:00Z]}}
      ])

      # A window long enough for live calls to finish on a busy machine; it
      # ends as soon as enough are compared.
      shadow_ms = Application.get_env(:theseus, :shadow_ms)
      Application.put_env(:theseus, :shadow_ms, 10_000)
      on_exit(fn -> Application.put_env(:theseus, :shadow_ms, shadow_ms) end)

      # The proposed version lists one note, and records new notes with n 1.
      proposed =
        @notes_unit
        |> String.replace(
          "Theseus.Store.all(:notes, order: [:text])",
          "Theseus.Store.all(:notes, order: [:text], limit: 1)"
        )
        |> String.replace("n: 0, ", "n: 1, ")

      {:ok, change, _} =
        Changes.propose(
          proposal(
            unit: "Sample.Notes",
            unit_source: proposed,
            intent: "one note, counted",
            behaviour_change: true
          )
        )

      assert change.status == :shadowing,
             inspect(Theseus.Changes.get(change.id) |> elem(2) |> Report.failure())

      http = fn method, path, body ->
        conn =
          Plug.Test.conn(method, path, body && JSON.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Theseus.Web.call(Theseus.Web.init([]))

        {conn.status, JSON.decode!(conn.resp_body)}
      end

      {_change, report} =
        settle(
          change.id,
          fn ->
            assert {200, %{"notes" => ["apple", "banana" | _]}} = http.(:get, "/notes", nil)
            assert {201, _} = http.(:post, "/notes", %{"text" => "cherry"})
          end,
          15_000
        )

      assert %{result: :info, detail: %{compared: compared, differ: compared, changed: rows}} =
               Report.stage(report, :shadow)

      assert compared > 0

      # Each GET's candidate read the notes the live request saw.
      gets = for %{args: [%{method: "GET"}]} = row <- rows, do: row
      assert gets != []

      for %{before: {:ok, {200, %{notes: seen}}}, after: after_} <- gets do
        assert after_ == {:ok, {200, %{notes: Enum.take(seen, 1)}}}
      end

      # A POST's writes differ, and only the live one was applied.
      assert Enum.any?(
               rows,
               &match?(
                 %{
                   args: [%{method: "POST"}],
                   after: {:ok, {:write, [{:insert, :notes, %{n: 1}}], _}}
                 },
                 &1
               )
             )

      assert read(fn -> Store.all(:notes, where: [n: 1]) end) |> Enum.map(& &1.id) == ["a"]
    end

    test "a replay side's writes hold no row: live requests on the same rows never wait" do
      write!([
        {:insert, :notes, %{id: "a", text: "apple", n: 1, at: ~U[2026-10-01 09:00:00Z]}},
        {:insert, :notes, %{id: "b", text: "banana", n: 2, at: ~U[2026-10-02 09:00:00Z]}}
      ])

      {:ok, holder, id} = Theseus.Store.DB.export_snapshot()
      on_exit(fn -> Theseus.Store.DB.release_snapshot(holder) end)

      snapshot = %{
        id: id,
        connection: Theseus.Store.DB.connection_opts(),
        prefix: Theseus.Store.DB.prefix()
      }

      # A side sets the store config, as it does on the sandbox.
      config = Application.get_env(:theseus, :store)

      {side, :snapshot} =
        Theseus.Store.Side.start(snapshot: snapshot, tables: Theseus.Store.DB.tables())

      Application.put_env(:theseus, :store, config)

      on_exit(fn -> Process.alive?(side) and Theseus.Store.Side.stop(side) end)

      written = fn ops -> Theseus.Store.Side.run(side, fn -> {:ok, {:write, ops, :ok}} end) end
      seen = fn fun -> Theseus.Store.Side.run(side, fn -> {:ok, fun.()} end) |> elem(0) end
      at = ~U[2026-10-03 09:00:00Z]

      assert {_, :ok} = written.([{:update, :notes, "a", %{n: 9}}])
      assert {_, :ok} = written.([{:delete, :notes, "b"}])
      assert {_, :ok} = written.([{:insert, :notes, %{id: "c", text: "cherry", n: 3, at: at}}])
      # A recorded insert whose row is there leaves it as it is.
      assert {_, :ok} = written.([{:insert, :notes, %{id: "a", text: "again", n: 0, at: at}}])
      assert {_, {:conflict, _}} = written.([{:update, :notes, "b", %{n: 5}}])
      assert {_, {:conflict, _}} = written.([{:update, :notes, "a", %{n: 5}, if: [n: 1]}])

      # The side sees its own writes laid over the rows.
      assert {:ok, [%{id: "a", n: 9}, %{id: "c", n: 3}]} = seen.(fn -> Store.all(:notes) end)
      assert {:ok, 1} = seen.(fn -> Store.count(:notes, where: [n: {:>, 5}]) end)

      # A live request updating the row the side wrote finishes at once.
      {ms, :ok} =
        :timer.tc(fn -> write!([{:update, :notes, "a", %{n: 7}}]) end, :millisecond)

      assert ms < 1_000
      assert read(fn -> Store.get(:notes, "a") end).n == 7
      assert read(fn -> Store.get(:notes, "b") end).text == "banana"

      # The side still sees the data as it was, with its writes.
      assert {:ok, %{n: 9}} = seen.(fn -> Store.get(:notes, "a") end)

      Theseus.Store.Side.stop(side)
      assert read(fn -> Store.get(:notes, "c") end) == nil
    end

    test "a store unit keeps a table's reads and writes, and an endpoint unit calls it" do
      store = """
      defmodule Sample.NoteStore do
        use Theseus.Store

        def texts, do: Enum.map(Theseus.Store.all(:notes, order: [:text]), & &1.text)

        def add(request, text) do
          row = %{id: Theseus.Store.id(request), text: text, n: 0, at: request.now}
          {:write, [{:insert, :notes, row}], row.id}
        end
      end
      """

      spec = """
      defmodule Sample.NoteStore.Spec do
        use Theseus.Spec

        spec Sample.NoteStore, deterministic: true do
          prose "Lists the notes' texts in order, and adds notes."

          example "no notes, no texts", texts: [], expect: []
        end
      end
      """

      {_change, report} =
        approve_settled(
          unit: "Sample.NoteStore",
          intent: "keep the notes table",
          unit_source: store,
          spec_source: spec
        )

      assert report.passed
      assert Theseus.Registry.fetch!(Sample.NoteStore).kind == :store

      routes =
        String.replace(
          fixture("routes.ex"),
          "  def handle(_request), do: {404, %{error: \"not found\"}}",
          """
            def handle(%{method: "POST", path: ["notes"], body: %{"text" => text}} = r) do
              {:write, ops, id} = Theseus.call(Sample.NoteStore, :add, [r, text])
              {:write, ops, {201, %{id: id}}}
            end

            def handle(%{method: "GET", path: ["notes"]}),
              do: {200, %{notes: Theseus.call(Sample.NoteStore, :texts, [])}}

            def handle(_request), do: {404, %{error: "not found"}}
          """
          |> String.trim_trailing()
        )

      promote_routes(routes)

      http = fn method, path, body ->
        conn =
          Plug.Test.conn(method, path, body && JSON.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Theseus.Web.call(Theseus.Web.init([]))

        {conn.status, JSON.decode!(conn.resp_body)}
      end

      assert {201, _} = http.(:post, "/notes", %{"text" => "pear"})
      assert {200, %{"notes" => ["pear"]}} = http.(:get, "/notes", nil)
      # Not a route: the store unit answers only through Theseus.call/3.
      assert Theseus.Web.endpoint() == Sample.Routes

      on_exit(fn ->
        Loader.unregister(Sample.NoteStore, actor: :system)
        Loader.unregister(Sample.NoteStore.Spec, actor: :system)
      end)
    end

    test "a schema change that adds a column is described for the reviewer" do
      bigger =
        String.replace(
          @schema,
          "n: :integer, ",
          "n: :integer, priority: {:integer, default: 0}, "
        )

      {:ok, change, report} =
        Changes.check(
          proposal(unit: "Sample.NotesSchema", unit_source: bigger, intent: "priority")
        )

      assert report.passed, inspect(Report.failure(report))

      assert Theseus.Describe.change(change, report).schema_changes == [
               "adds column notes.priority (integer, default 0)"
             ]
    end

    defp columns do
      %{rows: rows} =
        Postgrex.query!(
          Theseus.Store.Pool,
          "SELECT column_name, is_nullable FROM information_schema.columns WHERE table_schema = 'theseus_test' AND table_name = 'notes'",
          []
        )

      Map.new(rows, fn [name, nullable] -> {name, nullable == "YES"} end)
    end

    defp promote_routes(source) do
      {:ok, version} = Version.build(Sample.Routes, source, current(Sample.Routes))
      {:ok, _} = Loader.promote(version, actor: :system)
    end

    defp approved(source, intent) do
      {:ok, change, _} =
        Changes.propose(proposal(unit: "Sample.NotesSchema", unit_source: source, intent: intent))

      {change, report} = settle(change.id)
      assert change.status == :held, inspect(Report.failure(report))
      {:ok, _} = Changes.approve(change.id)
      {change, report}
    end

    test "a drop waits until no unit mentions what it drops" do
      promote_routes(notes_routes())
      smaller = String.replace(@schema, "n: :integer, ", "")

      {:ok, change, report} =
        Changes.check(
          proposal(unit: "Sample.NotesSchema", unit_source: smaller, intent: "drop n")
        )

      assert %{name: :static, detail: %{violations: violations}} = Report.failure(report)
      assert [why] = violations[Sample.NotesSchema]
      assert why =~ "drops notes.n, which Sample.Routes still mention"
      assert change.unit == Sample.NotesSchema

      # Changing the routes in the same group lets it through.
      {:ok, results} =
        Changes.check_group(%{
          intent: "drop n",
          proposer: %{kind: :test, client: "test"},
          units: [
            %{unit: "Sample.NotesSchema", unit_source: smaller},
            %{unit: "Sample.Routes", unit_source: String.replace(notes_routes(), "n: 0, ", "")}
          ]
        })

      for {c, r} <- results,
          do: assert(r.passed, "#{c.unit}: #{inspect(Report.failure(r), limit: 30)}")
    end

    test "approving a drop removes the column and its data, and nothing mentioning it comes back" do
      promote_routes(notes_routes())
      with_n = current(Sample.Routes)
      promote_routes(String.replace(notes_routes(), "n: 0, ", ""))
      schema_before = current(Sample.NotesSchema)
      write!([{:insert, :notes, %{id: "a", text: "apple", n: 3, at: ~U[2026-10-01 09:00:00Z]}}])

      smaller = String.replace(@schema, "n: :integer, ", "")
      {change, _} = approved(smaller, "drop n")
      assert change.unit == Sample.NotesSchema

      refute Map.has_key?(columns(), "n")
      assert read(fn -> Store.get(:notes, "a") end).text == "apple"

      assert Enum.any?(
               Theseus.Ledger.events(),
               &match?(
                 %{body: {:schema_migrated, Sample.NotesSchema, %{dropped_columns: [notes: :n]}}},
                 &1
               )
             )

      assert {:error, why} = Loader.rollback(Sample.NotesSchema, schema_before, actor: :human)
      assert why =~ "mentions notes.n, which a schema change dropped"
      assert {:error, why} = Loader.rollback(Sample.Routes, with_n, actor: :human)
      assert why =~ "Sample.Routes mentions notes.n"
    end

    test "approving a change to required columns and defaults changes the table to match" do
      write!([{:insert, :notes, %{id: "a", text: "apple", n: 3, at: ~U[2026-10-01 09:00:00Z]}}])

      changed =
        String.replace(
          @schema,
          "n: :integer, tag: {:text, null: true}",
          "n: {:integer, null: true}, tag: {:text, default: \"none\"}"
        )

      assert changed != @schema
      approved(changed, "n is optional; tag defaults to none")

      assert %{"n" => true, "tag" => false} = columns()
      # The row that had no tag was given the default.
      assert read(fn -> Store.get(:notes, "a") end).tag == "none"

      write!([{:insert, :notes, %{id: "b", text: "banana", at: ~U[2026-10-02 09:00:00Z]}}])
      assert %{n: nil, tag: "none"} = read(fn -> Store.get(:notes, "b") end)
    end

    test "a preview of live data overlays only the tables whose shape differs from live" do
      assert Theseus.Store.DB.differing(Theseus.Store.Pool, Theseus.Store.DB.tables()) == []

      {:ok, optional} =
        Theseus.Schema.normalize(%{
          notes: %{
            columns: %{
              text: :text,
              n: {:integer, null: true},
              tag: {:text, null: true},
              at: :utc_datetime
            },
            indexes: [[:tag]]
          },
          moods: %{columns: %{name: :text}}
        })

      assert Theseus.Store.DB.differing(Theseus.Store.Pool, optional) == [:moods, :notes]
    end

    @required_schema """
    defmodule Sample.NotesSchema do
      use Theseus.Schema

      def tables do
        %{notes: %{columns: %{text: :text, n: :integer, tag: :text, at: :utc_datetime}, indexes: [[:tag]]}}
      end

      def backfill(:notes, %{tag: nil} = row), do: %{tag: "t-" <> row.text}
    end
    """

    test "making a column required runs backfill/2, shown on the app's data first" do
      write!([
        {:insert, :notes,
         %{id: "a", text: "apple", n: 1, tag: nil, at: ~U[2026-10-01 09:00:00Z]}},
        {:insert, :notes,
         %{id: "b", text: "banana", n: 2, tag: "fruit", at: ~U[2026-10-02 09:00:00Z]}}
      ])

      no_backfill = String.replace(@required_schema, ~r/\n  def backfill.*\n/, "\n")

      {:ok, _, report} =
        Changes.check(
          proposal(unit: "Sample.NotesSchema", unit_source: no_backfill, intent: "tag")
        )

      assert %{name: :static, detail: %{violations: %{Sample.NotesSchema => [why]}}} =
               Report.failure(report)

      assert why =~ "makes notes.tag required with no default; define backfill/2"

      {change, report} = approved(@required_schema, "every note has a tag")

      lines =
        Theseus.Describe.change(change, report).stages |> Enum.find(&(&1.name == "backfill"))

      assert [line] = lines.lines
      assert line =~ "notes: backfill/2 sets 1 of 2 rows; a: %{tag: \"t-apple\"}"

      assert read(fn -> Store.get(:notes, "a") end).tag == "t-apple"
      assert read(fn -> Store.get(:notes, "b") end).tag == "fruit"
      assert columns()["tag"] == false

      assert Enum.any?(
               Theseus.Ledger.events(),
               &match?(
                 %{body: {:schema_migrated, _, %{required: [notes: :tag], filled: %{notes: 1}}}},
                 &1
               )
             )
    end

    test "a backfill that leaves a required column empty is rejected before it runs" do
      write!([
        {:insert, :notes, %{id: "a", text: "apple", n: 1, at: ~U[2026-10-01 09:00:00Z]}},
        {:insert, :notes, %{id: "b", text: "banana", n: 2, at: ~U[2026-10-02 09:00:00Z]}}
      ])

      partial =
        String.replace(
          @required_schema,
          ~s|def backfill(:notes, %{tag: nil} = row), do: %{tag: "t-" <> row.text}|,
          ~s|def backfill(:notes, %{text: "apple"}), do: %{tag: "a"}|
        )

      {:ok, _, report} =
        Changes.check(proposal(unit: "Sample.NotesSchema", unit_source: partial, intent: "tag"))

      assert %{name: :backfill, result: :fail} = Report.failure(report)
      assert columns()["tag"] == true
    end
  end

  test "only endpoint units read the store, naming tables with atoms" do
    check = fn module, source ->
      {:ok, v} = Version.build(module, source)
      Theseus.Validator.Static.check(v)
    end

    assert {:error, [why]} =
             check.(
               Demo.PureReads,
               "defmodule Demo.PureReads do\n def f, do: Theseus.Store.all(:notes)\nend"
             )

    assert why =~ "Theseus.Store is for endpoint and store units"

    assert :ok =
             check.(Demo.NoteStore, """
             defmodule Demo.NoteStore do
               use Theseus.Store
               def texts, do: Theseus.Store.all(:notes)
             end
             """)

    assert Theseus.Unit.infer_kind(
             Demo.NoteStore,
             Code.string_to_quoted!("defmodule Demo.NoteStore do\n use Theseus.Store\nend")
           ) == :store

    assert {:error, [why]} =
             check.(Demo.TableVar, """
             defmodule Demo.TableVar do
               use Theseus.Endpoint
               def handle(r), do: {200, Theseus.Store.all(r.table)}
             end
             """)

    assert why =~ "literal atom"

    assert :ok =
             check.(Demo.Reads, """
             defmodule Demo.Reads do
               use Theseus.Endpoint
               def handle(r), do: {200, Theseus.Store.all(:notes, where: [id: Theseus.Store.id(r)])}
             end
             """)

    assert {:error, [why]} =
             check.(Demo.JoinVar, """
             defmodule Demo.JoinVar do
               use Theseus.Endpoint
               def handle(r), do: {200, Theseus.Store.all(:notes, join: [x: {r.table, :tag}])}
             end
             """)

    assert why =~ "join: [name: {:table, :column}]"

    assert :ok =
             check.(Demo.Figures, """
             defmodule Demo.Figures do
               use Theseus.Endpoint

               def handle(_r) do
                 {200,
                  %{
                    tagged: Theseus.Store.all(:notes, join: [kind: {:tags, :tag}], where: [kind: [label: "Fruit"]]),
                    by_tag: Theseus.Store.aggregate(:notes, by: [:tag], compute: [n: :count])
                  }}
               end
             end
             """)
  end
end
