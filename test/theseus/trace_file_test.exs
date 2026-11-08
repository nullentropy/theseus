defmodule Theseus.TraceFileTest do
  use ExUnit.Case, async: false

  alias Theseus.{Redact, Trace, TraceFile, Traces}

  @dir Path.expand("../../tmp/test_trace_files", __DIR__)

  setup do
    File.rm_rf!(@dir)
    File.mkdir_p!(@dir)
    %{path: Path.join(@dir, "app.theseus.traces"), key: :crypto.strong_rand_bytes(32)}
  end

  defp trace(args, result \\ {:ok, :fine}) do
    %Trace{
      id: System.unique_integer([:positive, :monotonic]),
      unit: Sample.Input,
      fun: :parse,
      args: args,
      result: result,
      at: DateTime.utc_now()
    }
  end

  describe "redaction" do
    test "personal data in prompt text is replaced, the same way wherever it appears" do
      text =
        ~s|call(%{name: "Ada Lovelace", email: "Ada@acme.com"}, %{"last_name" => "Ross"}) then ada@acme.com|

      out = Theseus.Redact.personal(text)
      refute out =~ "Ada" or out =~ "Ross"
      assert [a, b] = Regex.scan(~r/person-[0-9A-F]+@acme\.com/, out) |> List.flatten()
      assert a == b
      assert out =~ ~s(name: "[name]")
      assert out =~ ~s("last_name" => "[name]")
    end

    test "sensitive keys, credentials in text and card numbers are replaced" do
      input = %{
        "user" => "ada",
        "Password" => "hunter2",
        "api_key" => "abc",
        "note" => "call me, my card is 4242 4242 4242 4242, order 1234567890123",
        "headers" => [{"authorization", "Bearer abc.def"}, {"x-trace", "Bearer abc.def"}],
        "opts" => [access_token: "t0k", limit: 5],
        "key" => "sk-abcdefghijklmnopqrstuvwxyz"
      }

      out = Redact.term(input)
      assert out["user"] == "ada"
      assert out["Password"] == "[redacted]"
      assert out["api_key"] == "[redacted]"
      assert out["note"] == "call me, my card is [redacted], order 1234567890123"
      assert out["headers"] == [{"authorization", "[redacted]"}, {"x-trace", "[redacted]"}]
      assert out["opts"] == [access_token: "[redacted]", limit: 5]
      assert out["key"] == "[redacted]"
    end

    test "structs and errors are walked too" do
      error = %KeyError{key: :password, term: %{password: "hunter2", name: "ada"}}
      assert %KeyError{term: %{password: "[redacted]", name: "ada"}} = Redact.term(error)
    end
  end

  describe "the file" do
    test "round trips, and holds no plain text", %{path: path, key: key} do
      {file, []} = TraceFile.open(path, key)
      :ok = TraceFile.append(file, trace([%{"sku" => "plain-text-sku"}]))
      :ok = TraceFile.close(file)

      refute File.read!(path) =~ "plain-text-sku"
      {file, [loaded]} = TraceFile.open(path, key)
      assert loaded.args == [%{"sku" => "plain-text-sku"}]
      TraceFile.close(file)
    end

    test "a file written with another key is moved aside", %{path: path, key: key} do
      {file, []} = TraceFile.open(path, key)
      :ok = TraceFile.append(file, trace([1]))
      :ok = TraceFile.close(file)

      {file, []} = TraceFile.open(path, :crypto.strong_rand_bytes(32))
      TraceFile.close(file)
      assert [_aside] = Path.wildcard(path <> ".unreadable-*")
    end

    test "a torn record at the end is dropped", %{path: path, key: key} do
      {file, []} = TraceFile.open(path, key)
      for i <- 1..3, do: :ok = TraceFile.append(file, trace([i]))
      :ok = TraceFile.close(file)

      File.write!(path, <<0, 0, 9, 0, 1, 2>>, [:append])
      {file, loaded} = TraceFile.open(path, key)
      assert Enum.map(loaded, & &1.args) == [[1], [2], [3]]
      TraceFile.close(file)
    end

    test "the key file is created once, readable only by its owner" do
      key_path = Path.join(@dir, "keys/trace.key")
      configured = Application.fetch_env!(:theseus, :trace_key_path)
      Application.put_env(:theseus, :trace_key_path, key_path)
      on_exit(fn -> Application.put_env(:theseus, :trace_key_path, configured) end)

      key = TraceFile.key()
      assert byte_size(key) == 32
      assert TraceFile.key() == key
      assert File.stat!(key_path).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(Path.dirname(key_path)).mode |> Bitwise.band(0o777) == 0o700
    end
  end

  test "recorded calls survive a restart, redacted" do
    {:ok, _} =
      Theseus.call(Sample.Input, :parse, [
        %{"items" => [], "coupon" => "SURVIVOR", "password" => "hunter2"}
      ])

    :ok = Supervisor.terminate_child(Theseus.Supervisor, Traces)
    {:ok, _} = Supervisor.restart_child(Theseus.Supervisor, Traces)

    assert [%{args: [body]} | _] =
             Enum.filter(Traces.list(Sample.Input), &match?([%{"coupon" => "SURVIVOR"}], &1.args))

    assert body["password"] == "[redacted]"
    refute File.read!(TraceFile.path()) =~ "SURVIVOR"
  end
end
