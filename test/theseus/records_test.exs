defmodule Theseus.RecordsTest do
  @moduledoc "The engine's records in Postgres: encrypted, rewritten, imported from a file once."

  use ExUnit.Case, async: false

  alias Theseus.{Records, SealedLog}

  @moduletag :postgres
  @key :crypto.hash(:sha256, "records test key")
  @other :crypto.hash(:sha256, "another key")
  @magic "THESEUSX"

  setup do
    Application.put_env(:theseus, :records, :database)

    case Postgrex.query(Theseus.Store.Pool, "SELECT 1", []) do
      {:ok, _} -> :ok
      _ -> raise "the test database is not reachable"
    end

    name = "test_#{System.unique_integer([:positive])}"
    dir = Path.expand("../../tmp/records_#{name}", __DIR__)

    on_exit(fn ->
      Application.put_env(:theseus, :records, :files)
      File.rm_rf!(dir)
    end)

    %{name: name, path: Path.join(dir, "app.theseus.x")}
  end

  defp raw(name) do
    %{rows: rows} =
      Postgrex.query!(
        Theseus.Store.Pool,
        ~s|SELECT data FROM "theseus_test"."_theseus_records" WHERE log = $1 ORDER BY seq|,
        [name]
      )

    for [d] <- rows, do: d
  end

  test "records are appended, read back in order, and rewritten", %{name: name, path: path} do
    {h, []} = Records.open(name, path, @key, @magic)
    :ok = Records.append(h, {:a, 1})
    :ok = Records.append(h, %{b: "secret value"})
    {h, terms} = Records.open(name, path, @key, @magic)
    assert terms == [{:a, 1}, %{b: "secret value"}]
    refute Enum.any?(raw(name), &(&1 =~ "secret value"))

    Records.rewrite(h, [{:only, :this}])
    assert {_, [{:only, :this}]} = Records.open(name, path, @key, @magic)
    refute File.exists?(path)
  end

  test "a file's records move into the database once", %{name: name, path: path} do
    {file, []} = SealedLog.open(path, @key, @magic)
    :ok = SealedLog.append(file, {:from, :file})
    SealedLog.close(file)

    assert {_, [{:from, :file}]} = Records.open(name, path, @key, @magic)
    refute File.exists?(path)
    assert File.exists?(path <> ".imported-to-database")
    assert {_, [{:from, :file}]} = Records.open(name, path, @key, @magic)
  end

  test "records written with another key are set aside", %{name: name, path: path} do
    {h, []} = Records.open(name, path, @key, @magic)
    :ok = Records.append(h, :kept)
    assert {_, []} = Records.open(name, path, @other, @magic)
    assert raw(name) == []
  end
end
