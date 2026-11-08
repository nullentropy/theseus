defmodule Theseus.LLMTest do
  use ExUnit.Case, async: false

  alias Theseus.LLM

  # A fake provider on this machine: records each request, answers from
  # the reply the test sets.
  defmodule Fake do
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      headers = Map.new(conn.req_headers)

      send(
        :persistent_term.get({__MODULE__, :test}),
        {:request, conn.request_path, headers, JSON.decode!(body)}
      )

      {status, reply} = :persistent_term.get({__MODULE__, :reply})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(reply))
    end
  end

  setup do
    :persistent_term.put({Fake, :test}, self())
    {:ok, server} = Bandit.start_link(plug: Fake, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    config = Application.get_env(:theseus, :llm)

    keys =
      for k <- ~w(ANTHROPIC_API_KEY THESEUS_LLM_API_KEY), into: %{}, do: {k, System.get_env(k)}

    on_exit(fn ->
      Application.put_env(:theseus, :llm, config)
      for {k, v} <- keys, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end)

    %{url: "http://127.0.0.1:#{port}"}
  end

  defp use_provider(provider, extra) do
    Application.put_env(:theseus, :llm, [provider: provider, timeout_ms: 5_000] ++ extra)
  end

  defp reply(status \\ 200, body), do: :persistent_term.put({Fake, :reply}, {status, body})

  @messages [%{role: :user, content: "Fix the crash."}]

  test "anthropic sends the Messages API request and reads the text blocks", %{url: url} do
    use_provider("anthropic", base_url: url)
    System.put_env("ANTHROPIC_API_KEY", "test-key")

    reply(%{
      "content" => [
        %{"type" => "thinking", "thinking" => ""},
        %{"type" => "text", "text" => "defmodule"}
      ],
      "stop_reason" => "end_turn"
    })

    assert LLM.available?()
    assert LLM.name() == "anthropic:claude-opus-5-5"
    assert {:ok, "defmodule"} = LLM.complete("You repair code.", @messages)

    assert_received {:request, "/v1/messages", headers, body}
    assert headers["x-api-key"] == "test-key"
    assert headers["anthropic-version"] == "2026-10-21"
    assert headers["anthropic-beta"] == "server-side-fallback-2026-07-01"

    assert %{
             "model" => "claude-opus-5-5",
             "system" => "You repair code.",
             "messages" => [%{"role" => "user", "content" => "Fix the crash."}],
             "output_config" => %{"effort" => "high"},
             "fallbacks" => "default"
           } = body

    refute Map.has_key?(body, "temperature")

    reply(%{
      "content" => [],
      "stop_reason" => "refusal",
      "stop_details" => %{"category" => "cyber"}
    })

    assert {:error, {:refused, "cyber"}} = LLM.complete("s", @messages)
    reply(%{"content" => [%{"type" => "text", "text" => "def"}], "stop_reason" => "max_tokens"})
    assert {:error, :truncated} = LLM.complete("s", @messages)
    reply(401, %{"error" => %{"message" => "invalid x-api-key"}})
    assert {:error, {:http, 401, "invalid x-api-key"}} = LLM.complete("s", @messages)

    System.delete_env("ANTHROPIC_API_KEY")
    refute LLM.available?()
    assert LLM.setup() == "set ANTHROPIC_API_KEY"
    assert {:error, :no_api_key} = LLM.complete("s", @messages)
  end

  test "an OpenAI-compatible server gets chat completions, with a key only when set", %{url: url} do
    use_provider("openai_compatible", base_url: url <> "/v1/", model: "qwen-coder")
    System.delete_env("THESEUS_LLM_API_KEY")

    reply(%{
      "choices" => [%{"message" => %{"content" => "defmodule"}, "finish_reason" => "stop"}]
    })

    assert LLM.name() == "openai_compatible:qwen-coder"
    assert {:ok, "defmodule"} = LLM.complete("You repair code.", @messages)
    assert_received {:request, "/v1/chat/completions", headers, body}
    refute Map.has_key?(headers, "authorization")

    assert body == %{
             "model" => "qwen-coder",
             "messages" => [
               %{"role" => "system", "content" => "You repair code."},
               %{"role" => "user", "content" => "Fix the crash."}
             ]
           }

    System.put_env("THESEUS_LLM_API_KEY", "test-key")
    assert {:ok, _} = LLM.complete("s", @messages)
    assert_received {:request, _, %{"authorization" => "Bearer test-key"}, _}

    reply(%{"choices" => [%{"message" => %{"content" => "def"}, "finish_reason" => "length"}]})
    assert {:error, :truncated} = LLM.complete("s", @messages)

    use_provider("openai_compatible", base_url: url)
    refute LLM.available?()
    assert {:error, :not_configured} = LLM.complete("s", @messages)
  end

  test "an unknown provider is named in the error" do
    use_provider("nope", [])

    assert_raise ArgumentError,
                 ~r/unknown model provider "nope"; use one of anthropic, openai/,
                 fn -> LLM.name() end
  end
end
