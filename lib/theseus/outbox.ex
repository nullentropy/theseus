defmodule Theseus.Outbox do
  @moduledoc """
  Messages the app sends, such as email. Units cannot reach the network, so
  an endpoint unit's callback returns its messages as data along with its
  answer: `{:send, messages, result}`, where `result` is what it would
  return otherwise. The engine queues each message here and carries on
  with `result`. Validation never queues anything: on the sandbox the
  messages are part of the result that replay and specs compare, so the
  review page shows which calls now send what, and nothing is sent.

  A message is a map with `to` (an email address or a list of them),
  `subject` and `text`, and optionally `link`, a path in the app such as
  "/requests" that is delivered as a full URL on the app's public address.
  A message that is not like this is dropped and logged.

  Delivery (config `:theseus, :outbox`):

    * `adapter: :hold`, the default, keeps messages on the review page's
      outbox without sending them.
    * `adapter: :webhook, url: url` (`THESEUS_OUTBOX_WEBHOOK`) posts each
      message as JSON to `url`, with `authorization: Bearer token` when
      `token` (`THESEUS_OUTBOX_TOKEN`) is set. A failed post is retried
      with delays growing from 2 seconds to an hour, for about five hours;
      after that the outbox page can send it again.

  The latest 1000 messages, and every message still waiting to be sent, are
  kept in an encrypted file next to the ledger, or in the database when
  there is one (`Theseus.Records`) (`<ledger>.outbox`, config
  `:outbox_path`; `outbox_file: false` keeps them in memory only), with the
  state key from `Theseus.Keys`. Messages waiting to be sent when the
  engine stops are sent after it starts. Ids are random, so a receiver can
  drop duplicates by id. Message contents never go into logs or crash
  reports.
  """

  use GenServer
  require Logger

  alias Theseus.{Keys, Records}

  @magic "THESEUSO"
  @keep 1_000
  # Retries back off from 2 s to at most an hour, so 16 attempts span about
  # five hours.
  @attempts 16

  @type message :: %{
          id: String.t(),
          to: [String.t()],
          subject: String.t(),
          text: String.t(),
          url: String.t() | nil,
          source: String.t(),
          at: DateTime.t(),
          status: :held | :queued | :sent | :failed,
          attempts: non_neg_integer(),
          error: String.t() | nil,
          sent_at: DateTime.t() | nil
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Takes a callback's result apart: queues the messages of `{:send,
  messages, result}` and returns `result`; returns anything else as it is.
  `source` says which call sent them, for the outbox page.
  """
  @spec take(term(), String.t()) :: term()
  def take(result, source) do
    {messages, result} = unwrap(result, [])
    if messages != [], do: send_messages(messages, source)
    result
  end

  @doc """
  The messages of a result and the result without them, through every
  layer: a root that adds messages around a sub-endpoint's result that
  already sends gives `{:send, outer, {:send, inner, result}}`.
  """
  @spec unwrap(term(), [term()]) :: {[term()], term()}
  def unwrap({:send, messages, result}, acc) when is_list(messages),
    do: unwrap(result, acc ++ messages)

  # htmx headers around a result that sends (see `Theseus.Endpoint`) stay,
  # and so do the requests it makes (`Theseus.Fetch`) and its writes.
  def unwrap({wrapper, extra, result}, acc) when wrapper in [:htmx, :fetch, :write] do
    {messages, result} = unwrap(result, acc)
    {messages, {wrapper, extra, result}}
  end

  def unwrap(result, acc), do: {acc, result}

  @doc "Queues messages. Returns how many were valid."
  @spec send_messages([map()], String.t()) :: non_neg_integer()
  def send_messages(messages, source) do
    {valid, invalid} =
      messages
      |> Enum.map(&normalize/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    for {:error, why} <- invalid,
        do: Logger.warning("#{source} tried to send a message that is not valid: #{why}")

    valid = for {:ok, m} <- valid, do: m

    if valid != [] do
      case Theseus.Leader.whereis(__MODULE__) do
        nil ->
          Logger.warning(
            "#{source} sent #{length(valid)} messages, but the outbox is not running"
          )

        pid ->
          # An exit here would carry the messages into a log; only count them.
          try do
            GenServer.call(pid, {:queue, valid, source})
          catch
            :exit, reason ->
              Logger.error(
                "#{source} sent #{length(valid)} messages, but the outbox did not take them " <>
                  "(#{exit_kind(reason)})"
              )
          end
      end
    end

    length(valid)
  end

  defp exit_kind({kind, _}) when is_atom(kind), do: kind
  defp exit_kind(kind) when is_atom(kind), do: kind
  defp exit_kind(_reason), do: :exit

  @doc "Queues a message that failed, or was held, to be sent again."
  @spec resend(String.t()) :: :ok | {:error, term()}
  def resend(id), do: GenServer.call(Theseus.Leader.name(__MODULE__), {:resend, id})

  @doc "The latest messages, newest first."
  @spec list(pos_integer()) :: [message()]
  def list(limit \\ 100), do: GenServer.call(Theseus.Leader.name(__MODULE__), {:list, limit})

  @doc "The outbox file's path."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:theseus, :outbox_path) ||
      Application.fetch_env!(:theseus, :ledger_path) <> ".outbox"
  end

  @doc false
  # A message as the app gave it, checked and in the outbox's shape (without
  # id, source, time or status).
  def normalize(%{} = m) do
    to = m |> Map.get(:to) |> List.wrap()
    subject = Map.get(m, :subject)
    text = Map.get(m, :text)
    link = Map.get(m, :link)

    cond do
      to == [] or not Enum.all?(to, &email?/1) ->
        {:error, "to must be one or more email addresses"}

      not (is_binary(subject) and subject != "" and byte_size(subject) <= 300 and
             String.valid?(subject) and not String.match?(subject, ~r/[[:cntrl:]]/)) ->
        {:error, "subject must be one line of text of up to 300 bytes"}

      not (is_binary(text) and byte_size(text) <= 50_000 and String.valid?(text)) ->
        {:error, "text must be text of up to 50 KB"}

      link != nil and Theseus.SignIn.local_path(link) == nil ->
        {:error, "link must be a path in the app, such as /requests"}

      true ->
        url = if link, do: Theseus.Web.public_url() <> Theseus.SignIn.local_path(link)
        {:ok, %{to: Enum.uniq(to), subject: subject, text: text, url: url}}
    end
  end

  def normalize(_other), do: {:error, "a message is a map with to, subject and text"}

  defp email?(to),
    do:
      is_binary(to) and String.valid?(to) and
        Regex.match?(~r/\A[^@\s<>,[:cntrl:]]+@[^@\s<>,[:cntrl:]]+\.[^@\s<>,[:cntrl:]]+\z/u, to)

  ## Server

  # Crash reports show the number of messages, never their contents.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{messages: messages} = state -> %{state | messages: "#{map_size(messages)} messages"}
      other -> other
    end)
  end

  @impl true
  def init(_opts) do
    {file, records} =
      if Application.get_env(:theseus, :outbox_file, true) do
        {file, terms} = Records.open("outbox", path(), Keys.state(), @magic, sync: true)
        {file, terms}
      else
        {nil, []}
      end

    messages =
      Enum.reduce(records, %{}, fn {:message, m}, acc -> Map.put(acc, m.id, m) end)
      |> keep_latest()

    file = if file, do: Records.rewrite(file, for(m <- Map.values(messages), do: {:message, m}))
    state = %{file: file, messages: messages}

    for %{status: :queued} = m <- Map.values(messages), do: send(self(), {:deliver, m.id})
    {:ok, state}
  end

  @impl true
  def handle_call({:queue, messages, source}, _from, state) do
    hold? = adapter() == :hold

    state =
      Enum.reduce(messages, state, fn m, state ->
        # Random, so ids never repeat, even after the file is moved aside.
        id = "msg-" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)

        message =
          Map.merge(m, %{
            id: id,
            source: source,
            at: DateTime.utc_now(),
            status: if(hold?, do: :held, else: :queued),
            attempts: 0,
            error: nil,
            sent_at: nil
          })

        unless hold?, do: send(self(), {:deliver, id})
        put(state, message)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:list, limit}, _from, state) do
    list =
      state.messages
      |> Map.values()
      |> Enum.sort_by(&order/1, :desc)
      |> Enum.take(limit)

    {:reply, list, state}
  end

  def handle_call({:resend, id}, _from, state) do
    case {state.messages[id], adapter()} do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {_m, :hold} ->
        {:reply, {:error, :held}, state}

      {%{status: status} = m, _} when status in [:failed, :held] ->
        send(self(), {:deliver, id})
        {:reply, :ok, put(state, %{m | status: :queued, attempts: 0, error: nil})}

      {%{status: status}, _} ->
        {:reply, {:error, status}, state}
    end
  end

  @impl true
  def handle_info({:deliver, id}, state) do
    case state.messages[id] do
      %{status: :queued} = m ->
        outbox = self()

        Task.Supervisor.start_child(Theseus.TaskSupervisor, fn ->
          send(outbox, {:delivered, id, deliver(m)})
        end)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:delivered, id, result}, state) do
    case {state.messages[id], result} do
      {nil, _} ->
        {:noreply, state}

      {m, :ok} ->
        {:noreply,
         put(state, %{
           m
           | status: :sent,
             attempts: m.attempts + 1,
             error: nil,
             sent_at: DateTime.utc_now()
         })}

      {m, {:error, why}} ->
        attempts = m.attempts + 1

        if attempts >= @attempts do
          Logger.warning("could not send #{id} after #{attempts} attempts: #{why}")
          {:noreply, put(state, %{m | status: :failed, attempts: attempts, error: why})}
        else
          Process.send_after(self(), {:deliver, id}, retry_ms(attempts))
          {:noreply, put(state, %{m | attempts: attempts, error: why})}
        end
    end
  end

  ## Internals

  defp put(state, message) do
    if state.file, do: Records.append(state.file, {:message, message})
    messages = Map.put(state.messages, message.id, message)

    if map_size(messages) > @keep * 2 do
      messages = keep_latest(messages)

      file =
        state.file &&
          Records.rewrite(state.file, for(m <- Map.values(messages), do: {:message, m}))

      %{state | messages: messages, file: file}
    else
      %{state | messages: messages}
    end
  end

  # The latest messages, and every message still waiting to be sent.
  defp keep_latest(messages) do
    {queued, others} = messages |> Map.values() |> Enum.split_with(&(&1.status == :queued))

    (queued ++ (others |> Enum.sort_by(&order/1, :desc) |> Enum.take(@keep)))
    |> Map.new(&{&1.id, &1})
  end

  defp order(m), do: {DateTime.to_unix(m.at, :microsecond), m.id}

  defp retry_ms(attempts) do
    base = Keyword.get(config(), :retry_ms, 2_000)
    cap = Keyword.get(config(), :max_retry_ms, 3_600_000)
    min(base * Integer.pow(2, attempts - 1), cap)
  end

  defp config, do: Application.get_env(:theseus, :outbox, [])
  defp adapter, do: Keyword.get(config(), :adapter, :hold)

  defp deliver(m) do
    case adapter() do
      :webhook -> webhook(m)
      other -> {:error, "no delivery for adapter #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp webhook(m) do
    url = Keyword.fetch!(config(), :url)
    token = Keyword.get(config(), :token)
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    body =
      JSON.encode!(%{
        id: m.id,
        to: m.to,
        subject: m.subject,
        text: m.text,
        url: m.url,
        app: Theseus.Web.public_url()
      })

    case Theseus.HTTP.request(:post, url, headers, {"application/json", body}, timeout: 10_000) do
      {:ok, status, _body} when status in 200..299 -> :ok
      {:ok, status, _body} -> {:error, "the webhook answered #{status}"}
      {:error, reason} -> {:error, "the webhook could not be reached (#{inspect(reason)})"}
    end
  end
end
