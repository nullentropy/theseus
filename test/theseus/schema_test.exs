defmodule Theseus.SchemaTest do
  @moduledoc "Schema units: tables read from the syntax tree, changes that only add, and their SQL."

  use ExUnit.Case, async: true

  alias Theseus.Schema

  defp tables(body) do
    {:ok, ast} = Code.string_to_quoted("defmodule S do\n use Theseus.Schema\n#{body}\nend")
    Schema.from_ast(ast)
  end

  test "tables are read from a literal tables/0, with an id key" do
    assert {:ok, %{notes: %{columns: columns, indexes: [[:at]]}}} =
             tables("""
             def tables do
               %{notes: %{columns: %{text: :text, at: :utc_datetime, done: {:boolean, default: false}, tag: {:text, null: true}}, indexes: [[:at]]}}
             end
             """)

    assert columns.id == %{type: :text, null: false, default: nil}
    assert columns.text == %{type: :text, null: false, default: nil}
    assert columns.done == %{type: :boolean, null: false, default: false}
    assert columns.tag == %{type: :text, null: true, default: nil}

    assert {:ok, %{notes: %{columns: %{tags: tags}}}} =
             tables("def tables, do: %{notes: %{columns: %{tags: {:texts, default: []}}}}")

    assert tags == %{type: :texts, null: false, default: []}
    assert Schema.type?(:texts, ["a", "b"]) and not Schema.type?(:texts, ["a", 1])

    assert {:error, message} =
             tables("def tables, do: %{notes: %{columns: %{tags: {:texts, default: [1]}}}}")

    assert message =~ "not a list of text"
  end

  test "a schema that is not literal data, or not well formed, says why" do
    for {body, why} <- [
          {"def tables, do: Map.new()", "literal map"},
          {"def other, do: %{}", "defines tables/0"},
          {"def tables, do: %{notes: %{columns: %{text: :string}}}", "has type :string"},
          {"def tables, do: %{Notes: %{columns: %{text: :text}}}", "not a table name"},
          {"def tables, do: %{notes: %{columns: %{id: :integer}}}", "notes.id is the key"},
          {"def tables, do: %{notes: %{columns: %{n: {:integer, default: \"x\"}}}}",
           "default is not an integer"},
          {"def tables, do: %{notes: %{columns: %{n: :integer}, indexes: [[:m]]}}",
           "names :m, not a column"},
          {"def tables, do: %{notes: %{columns: %{n: :integer}, keys: []}}",
           "it takes columns: and indexes:"}
        ] do
      assert {:error, message} = tables(body)
      assert message =~ why
    end
  end

  test "a plan says what a change drops, requires and retypes" do
    {:ok, old} =
      Schema.normalize(%{
        notes: %{columns: %{text: :text, tag: {:text, null: true}, n: :integer}, indexes: [[:n]]},
        gone: %{columns: %{x: :text}}
      })

    {:ok, grown} =
      Schema.normalize(%{
        notes: %{
          columns: %{
            text: :text,
            tag: {:text, null: true},
            n: :integer,
            seen: {:boolean, null: true},
            k: {:integer, default: 0}
          },
          indexes: [[:n]]
        },
        gone: %{columns: %{x: :text}},
        tags: %{columns: %{name: :text}}
      })

    assert Schema.additive?(Schema.plan(old, grown))
    assert Schema.refusals(Schema.plan(old, grown), false) == []

    {:ok, new} =
      Schema.normalize(%{
        notes: %{columns: %{text: :integer, tag: :text, kind: :text}, indexes: []}
      })

    plan = Schema.plan(old, new)
    assert plan.drop_tables == [:gone]
    assert plan.drop_columns == [notes: :n]
    assert plan.drop_indexes == [notes: [:n]]
    assert plan.required == [notes: :kind, notes: :tag]
    assert plan.type_changes == [{:notes, :text, :text, :integer}]

    [retype | required] = Schema.refusals(plan, false)
    assert retype =~ "changes notes.text from text to integer; types do not change"
    assert Enum.map(required, &(&1 =~ "define backfill/2")) == [true, true]
    assert [_retype] = Schema.refusals(plan, true)

    assert Schema.describe_drops(old, new) == [
             "drops table gone and every row in it",
             "drops column notes.n and everything in it"
           ]

    assert Schema.finish_ddl("app", plan) == [
             ~s|ALTER TABLE "app"."notes" ALTER COLUMN "kind" SET NOT NULL|,
             ~s|ALTER TABLE "app"."notes" ALTER COLUMN "tag" SET NOT NULL|,
             ~s|DROP INDEX IF EXISTS "app"."notes_n_idx"|,
             ~s|ALTER TABLE "app"."notes" DROP COLUMN IF EXISTS "n"|,
             ~s|DROP TABLE IF EXISTS "app"."gone"|
           ]
  end

  test "a plan says which columns become optional, take a default, or are required with one" do
    {:ok, old} =
      Schema.normalize(%{
        notes: %{columns: %{a: :text, b: {:text, null: true}, c: {:integer, default: 1}}}
      })

    {:ok, new} =
      Schema.normalize(%{
        notes: %{columns: %{a: {:text, null: true}, b: {:text, default: "x"}, c: :integer}}
      })

    plan = Schema.plan(old, new)
    assert plan.relaxed == [notes: :a]
    assert [{:notes, :b, %{default: "x"}}] = plan.defaulted
    assert [{:notes, :b, _}, {:notes, :c, %{default: nil}}] = plan.defaults
    assert plan.required == []
    refute Schema.additive?(plan)

    assert Schema.finish_ddl("app", plan) == [
             ~s|ALTER TABLE "app"."notes" ALTER COLUMN "b" SET DEFAULT 'x'|,
             ~s|ALTER TABLE "app"."notes" ALTER COLUMN "c" DROP DEFAULT|,
             ~s|ALTER TABLE "app"."notes" ALTER COLUMN "a" DROP NOT NULL|,
             ~s|UPDATE "app"."notes" SET "b" = 'x' WHERE "b" IS NULL|,
             ~s|ALTER TABLE "app"."notes" ALTER COLUMN "b" SET NOT NULL|
           ]

    assert Schema.describe_changes(old, new) == [
             ~s|makes notes.b required, giving empty rows "x"|,
             "makes notes.a optional",
             ~s|sets the default of notes.b to "x"|,
             "removes the default of notes.c"
           ]
  end

  test "a table may be declared by one schema unit only" do
    {:ok, a} = Schema.normalize(%{notes: %{columns: %{text: :text}}})
    assert {:error, "table notes is declared in two schema units"} = Schema.merge([a, a])
  end

  test "the SQL creates only what is missing, so it can run again" do
    {:ok, tables} =
      Schema.normalize(%{
        notes: %{columns: %{text: :text, n: {:integer, default: 0}}, indexes: [[:n, :text]]}
      })

    assert Schema.ddl("app", tables) == [
             ~s|CREATE SCHEMA IF NOT EXISTS "app"|,
             ~s|CREATE TABLE IF NOT EXISTS "app"."notes" ("id" text NOT NULL PRIMARY KEY, "n" bigint NOT NULL DEFAULT 0, "text" text NOT NULL)|,
             ~s|ALTER TABLE "app"."notes" ADD COLUMN IF NOT EXISTS "n" bigint NOT NULL DEFAULT 0|,
             ~s|ALTER TABLE "app"."notes" ADD COLUMN IF NOT EXISTS "text" text|,
             ~s|CREATE INDEX IF NOT EXISTS "notes_n_text_idx" ON "app"."notes" ("n", "text")|
           ]
  end
end
