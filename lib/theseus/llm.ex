defmodule Theseus.LLM do
  @moduledoc """
  The model the engine talks to, for crash repair, rewriting units that
  changed many times, and reading spec rules against their sentences.
  People work through their own agents over MCP.

  The provider is config `:llm, :provider`, or `THESEUS_LLM`:

    * `openai` (the default): the OpenAI Responses API, `OPENAI_API_KEY`.
    * `anthropic`: the Anthropic Messages API, `ANTHROPIC_API_KEY`.
    * `openai_compatible`: any server with an OpenAI-style
      `/chat/completions` endpoint (Ollama, vLLM, LM Studio, most hosted
      providers), at `THESEUS_LLM_URL`, with `THESEUS_LLM_API_KEY` if it
      needs one. `THESEUS_MODEL` must name the model.

  `THESEUS_MODEL` picks the model for any of them. Config `:llm, :module`
  names an implementation of this behaviour directly (tests use
  `Theseus.LLM.Stub`). Every exchange is kept in memory (`Theseus.LLM.Log`,
  redacted, last 50) for debugging. Prompts contain unit source, so they
  are never written to disk.
  """

  @type message :: %{role: :user | :assistant, content: String.t()}

  @callback complete(system :: String.t(), [message()], keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback available?() :: boolean()
  @callback name() :: String.t()
  @doc "What to set to make the model available, for the dashboard."
  @callback setup() :: String.t()

  @providers %{
    "openai" => Theseus.LLM.OpenAI,
    "anthropic" => Theseus.LLM.Anthropic,
    "openai_compatible" => Theseus.LLM.OpenAICompatible
  }

  @spec complete(String.t(), [message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(system, messages, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    result = impl().complete(system, messages, opts)

    Theseus.LLM.Log.add(%{
      at: DateTime.utc_now(),
      model: name(),
      ms: System.monotonic_time(:millisecond) - started,
      system: system,
      messages: messages,
      result: result
    })

    result
  end

  @doc "Whether the configured model can be called (for OpenAI: an API key is set)."
  def available?, do: impl().available?()

  @doc "The model, as recorded on changes: `openai:gpt-6.1-sol`."
  def name, do: impl().name()

  @doc "What to set to make the model available, for the dashboard."
  def setup, do: impl().setup()

  def config, do: Application.get_env(:theseus, :llm, [])

  @doc false
  # The model config names, or the provider's default.
  def model(default), do: Keyword.get(config(), :model) || default

  defp impl do
    case Keyword.get(config(), :module) do
      nil ->
        provider = to_string(Keyword.get(config(), :provider, "openai"))

        Map.get(@providers, provider) ||
          raise ArgumentError,
                "unknown model provider #{inspect(provider)}; use one of #{Enum.join(Enum.sort(Map.keys(@providers)), ", ")}"

      module ->
        module
    end
  end

  @doc false
  # Posts JSON and decodes the JSON reply, for the providers.
  def post_json(url, headers, body, timeout) do
    case Theseus.HTTP.request(:post, url, headers, {"application/json", JSON.encode!(body)},
           timeout: timeout
         ) do
      {:ok, 200, response} -> {:ok, JSON.decode!(response)}
      {:ok, status, response} -> {:error, {:http, status, error_message(response)}}
      {:error, _} = error -> error
    end
  end

  defp error_message(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      _ -> String.slice(body, 0, 300)
    end
  end

  @doc false
  def key(env) do
    case System.get_env(env) do
      key when key not in [nil, ""] -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end

  @doc false
  def timeout, do: Keyword.get(config(), :timeout_ms, 180_000)

  @doc false
  def extra, do: Keyword.get(config(), :extra, %{})
end

defmodule Theseus.LLM.OpenAI do
  @moduledoc """
  The OpenAI Responses API. The key is read from `OPENAI_API_KEY` at call
  time and never stored. Config `:llm`: `:model` (default `gpt-6.1-sol`,
  or `THESEUS_MODEL`), `:base_url`, `:timeout_ms`, and `:extra`, a map
  merged into every request body (for example reasoning settings).
  """

  @behaviour Theseus.LLM

  @default_model "gpt-6.1-sol"

  @impl true
  def available?, do: match?({:ok, _}, Theseus.LLM.key("OPENAI_API_KEY"))

  @impl true
  def name, do: "openai:" <> model()

  @impl true
  def setup, do: "set OPENAI_API_KEY"

  defp model, do: Theseus.LLM.model(@default_model)

  @impl true
  def complete(system, messages, _opts) do
    with {:ok, key} <- Theseus.LLM.key("OPENAI_API_KEY") do
      body =
        %{
          model: model(),
          # Prompts hold unit source and recorded calls; OpenAI keeps none of it.
          store: false,
          instructions: system,
          input: Enum.map(messages, &%{role: to_string(&1.role), content: &1.content})
        }
        |> Map.merge(Theseus.LLM.extra())

      url =
        Keyword.get(Theseus.LLM.config(), :base_url, "https://api.openai.com/v1") <> "/responses"

      with {:ok, response} <-
             Theseus.LLM.post_json(
               url,
               [{"authorization", "Bearer " <> key}],
               body,
               Theseus.LLM.timeout()
             ),
           do: parse(response)
    end
  end

  defp parse(%{"status" => "completed", "output" => output}) do
    text =
      for %{"type" => "message", "content" => content} <- output,
          %{"type" => "output_text", "text" => text} <- content,
          into: "",
          do: text

    if text == "", do: {:error, :empty_reply}, else: {:ok, text}
  end

  defp parse(%{"status" => status} = response),
    do: {:error, {:not_completed, status, response["incomplete_details"] || response["error"]}}
end

defmodule Theseus.LLM.Anthropic do
  @moduledoc """
  The Anthropic Messages API. The key is read from `ANTHROPIC_API_KEY` at
  call time and never stored. Config `:llm`: `:model` (default
  `claude-opus-5-5`, or `THESEUS_MODEL`), `:base_url`, `:timeout_ms`, and
  `:extra`, a map merged into every request body. Effort is `high` unless
  `:extra` sets `output_config`. A request a safety classifier declines is
  retried on another model by the API (`fallbacks: "default"`); a reply
  still declined, or cut off at `max_tokens`, is an error.
  """

  @behaviour Theseus.LLM

  @default_model "claude-opus-5-5"
  @version "2026-10-21"
  @max_tokens 16_000

  @impl true
  def available?, do: match?({:ok, _}, Theseus.LLM.key("ANTHROPIC_API_KEY"))

  @impl true
  def name, do: "anthropic:" <> model()

  @impl true
  def setup, do: "set ANTHROPIC_API_KEY"

  defp model, do: Theseus.LLM.model(@default_model)

  @impl true
  def complete(system, messages, _opts) do
    with {:ok, key} <- Theseus.LLM.key("ANTHROPIC_API_KEY") do
      body =
        %{
          model: model(),
          max_tokens: @max_tokens,
          system: system,
          messages: Enum.map(messages, &%{role: to_string(&1.role), content: &1.content}),
          output_config: %{effort: "high"},
          fallbacks: "default"
        }
        |> Map.merge(Theseus.LLM.extra())

      headers = [
        {"x-api-key", key},
        {"anthropic-version", @version},
        {"anthropic-beta", "server-side-fallback-2026-07-01"}
      ]

      url =
        Keyword.get(Theseus.LLM.config(), :base_url, "https://api.anthropic.com") <>
          "/v1/messages"

      with {:ok, response} <- Theseus.LLM.post_json(url, headers, body, Theseus.LLM.timeout()),
           do: parse(response)
    end
  end

  defp parse(%{"stop_reason" => "refusal"} = response),
    do: {:error, {:refused, get_in(response, ["stop_details", "category"])}}

  defp parse(%{"stop_reason" => "max_tokens"}), do: {:error, :truncated}

  defp parse(%{"content" => content}) do
    text = for %{"type" => "text", "text" => t} <- content, into: "", do: t
    if text == "", do: {:error, :empty_reply}, else: {:ok, text}
  end

  defp parse(response), do: {:error, {:unexpected_reply, Map.take(response, ["type", "error"])}}
end

defmodule Theseus.LLM.OpenAICompatible do
  @moduledoc """
  Any server with an OpenAI-style chat completions endpoint: Ollama, vLLM,
  LM Studio and most hosted providers. Config `:llm`: `:base_url` (or
  `THESEUS_LLM_URL`, for example `http://localhost:11434/v1`), `:model`
  (or `THESEUS_MODEL`, required), `:timeout_ms` and `:extra`. A key, when
  the server needs one, is read from `THESEUS_LLM_API_KEY` at call time.
  """

  @behaviour Theseus.LLM

  @impl true
  def available?, do: base_url() != nil and Theseus.LLM.model(nil) != nil

  @impl true
  def name, do: "openai_compatible:" <> (Theseus.LLM.model(nil) || "no model set")

  @impl true
  def setup, do: "set THESEUS_LLM_URL and THESEUS_MODEL"

  defp base_url, do: Keyword.get(Theseus.LLM.config(), :base_url)

  @impl true
  def complete(system, messages, _opts) do
    if available?() do
      body =
        %{
          model: Theseus.LLM.model(nil),
          messages: [
            %{role: "system", content: system}
            | Enum.map(messages, &%{role: to_string(&1.role), content: &1.content})
          ]
        }
        |> Map.merge(Theseus.LLM.extra())

      headers =
        case Theseus.LLM.key("THESEUS_LLM_API_KEY") do
          {:ok, key} -> [{"authorization", "Bearer " <> key}]
          _ -> []
        end

      url = String.trim_trailing(base_url(), "/") <> "/chat/completions"

      with {:ok, response} <- Theseus.LLM.post_json(url, headers, body, Theseus.LLM.timeout()),
           do: parse(response)
    else
      {:error, :not_configured}
    end
  end

  defp parse(%{"choices" => [%{"finish_reason" => "length"} | _]}), do: {:error, :truncated}

  defp parse(%{"choices" => [%{"message" => %{"content" => text}} | _]})
       when is_binary(text) and text != "",
       do: {:ok, text}

  defp parse(%{"choices" => [_ | _]}), do: {:error, :empty_reply}
  defp parse(response), do: {:error, {:unexpected_reply, Map.take(response, ["error"])}}
end

defmodule Theseus.LLM.Stub do
  @moduledoc """
  For tests and demos: replies come from a function set with `reply/1`,
  `fn system, messages -> {:ok, text} | {:error, reason} end`.
  """

  @behaviour Theseus.LLM

  def reply(fun) when is_function(fun, 2), do: Application.put_env(:theseus, __MODULE__, fun)

  @impl true
  def available?, do: true

  @impl true
  def name, do: "stub"

  @impl true
  def setup, do: ""

  @impl true
  def complete(system, messages, _opts) do
    case Application.get_env(:theseus, __MODULE__) do
      nil -> {:error, :no_stub_reply}
      fun -> fun.(system, messages)
    end
  end
end

defmodule Theseus.LLM.Log do
  @moduledoc "The last 50 LLM exchanges, redacted, in memory only."

  use Agent

  @keep 50

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def add(entry) do
    entry = Theseus.Redact.term(entry)
    Agent.update(__MODULE__, &Enum.take([entry | &1], @keep))
  catch
    :exit, _ -> :ok
  end

  @doc "Exchanges, newest first."
  def list, do: Agent.get(__MODULE__, & &1)
end
