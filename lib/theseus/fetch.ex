defmodule Theseus.Fetch do
  @moduledoc """
  Requests the app makes to outside services. Units cannot reach the
  network, so a callback returns its requests as data around its answer:
  `{:fetch, requests, result}`. The engine sends them once the call's
  writes are committed, never while it answers, and calls the root
  endpoint unit's `fetched/1` with each response, like any callback: its
  result may write, send messages and make more requests, such as for the
  next page.

  Validation never sends anything. On the sandbox the requests are part of
  the result that replay and specs compare, and a recorded `fetched/1`
  call carries the response it got, so replay runs the proposed code on the
  same response.

  A request is a map:

    * `service`: a service the app declares (`Theseus.Services`). The URL
      must start with one of the service's `urls`.
    * `domain`: whose connection to use, for a service with `connect`;
      the engine adds that connection's token.
    * `method`: "GET" (the default), "POST", "PUT", "PATCH" or "DELETE".
    * `url`, and `query`, a map added to it.
    * `headers`: other headers, a map. The engine sets `authorization`.
    * `body`: a map or list is sent as JSON; text is sent as it is, with
      the `content-type` header the request gives.
    * `context`: any small term. It comes back with the response, so the
      app knows what the response is for.

  `fetched/1` gets `%{request, status, headers, body, error, now, id}`.
  `status` is the HTTP status, or nil when there was no answer or the
  engine refused the request, with `error` saying why. `body` is decoded
  JSON when the answer is JSON, text otherwise. `request` is the request
  as the app made it. Tokens never appear in either.

  A GET without an answer, or answered 429 or 5xx, is tried again twice,
  after 1 and 5 seconds. A 401 on a connection renews its token and tries
  once more.

  Config `:fetch`: `concurrency` (4), `per_minute` requests per service
  (120; more wait their turn), `max_queue` (1000), `max_body_bytes`
  (10 MB), `timeout_ms` (30 s), and `enabled: false`, which drops every
  request (previews).
  """

  use GenServer
  require Logger

  alias Theseus.{Connections, Effects, HTTP, Services}

  @methods ~w(GET POST PUT PATCH DELETE)
  @keys [:service, :domain, :method, :url, :query, :headers, :body, :context]
  @forbidden_headers ~w(authorization cookie host content-length)
  @max_context_bytes 65_536
  @max_requests 50

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Takes a callback's result apart: queues the requests of `{:fetch,
  requests, result}` and returns `result`; returns anything else as it is.
  """
  @spec take(term(), String.t()) :: term()
  def take(result, source) do
    {requests, result} = unwrap(result, [])
    if requests != [], do: queue(requests, source)
    result
  end

  @doc "The requests of a result and the result without them, through every layer."
  @spec unwrap(term(), [term()]) :: {[term()], term()}
  def unwrap({:fetch, requests, result}, acc) when is_list(requests),
    do: unwrap(result, acc ++ requests)

  def unwrap({wrapper, extra, result}, acc) when wrapper in [:send, :htmx, :write] do
    {requests, result} = unwrap(result, acc)
    {requests, {wrapper, extra, result}}
  end

  def unwrap(result, acc), do: {acc, result}

  @doc "Waits until no request is waiting or running (for tests and iex)."
  @spec settle(timeout()) :: :ok
  def settle(timeout \\ 10_000),
    do: GenServer.call(Theseus.Leader.name(__MODULE__), :settle, timeout)

  @doc "Why a request is not valid, or the request with its defaults."
  @spec normalize(term()) :: {:ok, map()} | {:error, String.t()}
  def normalize(%{} = request) when not is_struct(request) do
    unknown = Map.keys(request) -- @keys
    service = request[:service]
    method = request |> Map.get(:method, "GET") |> to_string() |> String.upcase()

    with :ok <-
           must(unknown == [], "a request has no #{Enum.map_join(unknown, ", ", &inspect/1)}"),
         :ok <-
           must(
             (is_binary(service) or is_atom(service)) and service not in [nil, true, false],
             "a request names its service"
           ),
         :ok <- must(is_binary(request[:url]), "a request has a url"),
         :ok <- must(method in @methods, "#{method} is not a method the engine sends"),
         :ok <- must(is_nil(request[:domain]) or is_binary(request[:domain]), "domain is text"),
         {:ok, query} <- query(Map.get(request, :query, %{})),
         {:ok, headers} <- headers(Map.get(request, :headers, %{})),
         :ok <- body(request[:body], headers),
         :ok <-
           must(
             byte_size(:erlang.term_to_binary(request[:context])) <= @max_context_bytes,
             "a request's context is at most 64 KB"
           ) do
      {:ok,
       %{
         service: to_string(service),
         domain: request[:domain],
         method: method,
         url: request.url,
         query: query,
         headers: headers,
         body: request[:body],
         context: request[:context]
       }}
    end
  end

  def normalize(_request), do: {:error, "a request is a map"}

  defp query(query) when is_map(query) do
    Enum.reduce_while(query, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      if (is_atom(k) or is_binary(k)) and (is_binary(v) or is_number(v) or is_boolean(v)),
        do: {:cont, {:ok, Map.put(acc, to_string(k), to_string(v))}},
        else: {:halt, {:error, "query maps names to text or numbers"}}
    end)
  end

  defp query(_query), do: {:error, "query is a map"}

  defp headers(headers) when is_map(headers) or is_list(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn
      {k, v}, {:ok, acc} when (is_atom(k) or is_binary(k)) and is_binary(v) ->
        name = k |> to_string() |> String.downcase()

        if name in @forbidden_headers,
          do: {:halt, {:error, "the engine sets the #{name} header"}},
          else: {:cont, {:ok, Map.put(acc, name, v)}}

      _, _ ->
        {:halt, {:error, "headers map names to text"}}
    end)
  end

  defp headers(_headers), do: {:error, "headers is a map"}

  defp body(nil, _headers), do: :ok
  defp body(body, _headers) when is_map(body) or is_list(body), do: :ok

  defp body(body, headers) when is_binary(body),
    do: must(Map.has_key?(headers, "content-type"), "a text body needs a content-type header")

  defp body(_body, _headers), do: {:error, "a body is a map, a list or text"}

  defp must(true, _why), do: :ok
  defp must(false, why), do: {:error, why}

  @doc """
  The URL a request goes to, with its query, or why the service may not be
  sent it.
  """
  @spec url(map(), Services.service() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def url(request, nil), do: {:error, "the app declares no service #{request.service}"}

  def url(request, service) do
    url =
      if request.query == %{},
        do: request.url,
        else:
          request.url <>
            if(String.contains?(request.url, "?"), do: "&", else: "?") <>
            URI.encode_query(Enum.sort(request.query))

    uri = URI.parse(url)
    segments = String.split(URI.decode(uri.path || ""), "/")

    cond do
      uri.scheme != "https" or uri.userinfo != nil or uri.fragment != nil ->
        {:error, "requests go to plain https URLs"}

      Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, "a request's path may not have . or .. in it"}

      not Enum.any?(service.urls, &String.starts_with?(url, &1)) ->
        {:error,
         "#{service.name} may only be sent requests under #{Enum.join(service.urls, ", ")}"}

      true ->
        {:ok, url}
    end
  end

  defp config, do: Application.get_env(:theseus, :fetch, [])

  defp queue(requests, source) do
    cond do
      Keyword.get(config(), :enabled, true) == false ->
        Logger.info("#{source} made #{length(requests)} requests; this node sends none")

      length(requests) > @max_requests ->
        Logger.warning(
          "#{source} made #{length(requests)} requests at once; at most #{@max_requests}"
        )

        refuse(
          Enum.take(requests, @max_requests),
          "a call makes at most #{@max_requests} requests"
        )

      Theseus.Leader.whereis(__MODULE__) == nil ->
        Logger.warning(
          "#{source} made #{length(requests)} requests, but requests are not running"
        )

      true ->
        {valid, invalid} =
          Enum.split_with(Enum.map(requests, &{&1, normalize(&1)}), &match?({_, {:ok, _}}, &1))

        for {request, {:error, why}} <- invalid, do: refuse([request], why)

        if valid != [],
          do:
            GenServer.cast(
              Theseus.Leader.name(__MODULE__),
              {:queue, for({_, {:ok, r}} <- valid, do: r)}
            )
    end
  end

  # A request the engine will not send still gets its answer, saying why.
  defp refuse(requests, why) do
    Task.Supervisor.start_child(Theseus.TaskSupervisor, fn ->
      for request <- requests, do: deliver(response(request, nil, %{}, nil, why))
    end)
  end

  # Server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{queue: :queue.new(), running: %{}, sent: %{}, waiting: [], timer: nil}}
  end

  @impl true
  def handle_cast({:queue, requests}, state) do
    max = Keyword.get(config(), :max_queue, 1000)
    room = max(max - :queue.len(state.queue), 0)
    {kept, over} = Enum.split(requests, room)
    if over != [], do: refuse(over, "too many requests are waiting")
    state = %{state | queue: Enum.reduce(kept, state.queue, &:queue.in/2)}
    {:noreply, pump(state)}
  end

  @impl true
  def handle_call(:settle, from, state) do
    if idle?(state),
      do: {:reply, :ok, state},
      else: {:noreply, %{state | waiting: [from | state.waiting]}}
  end

  @impl true
  def handle_info(:pump, state), do: {:noreply, pump(%{state | timer: nil})}

  def handle_info({ref, _done}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finished(ref) |> pump() |> release()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    Logger.warning(
      "a request to #{state.running[ref].service} crashed: #{inspect(reason, limit: 3)}"
    )

    {:noreply, state |> finished(ref) |> pump() |> release()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finished(state, ref), do: %{state | running: Map.delete(state.running, ref)}

  defp idle?(state), do: state.running == %{} and :queue.is_empty(state.queue)

  defp release(%{waiting: waiting} = state) when waiting != [] do
    if idle?(state) do
      for from <- waiting, do: GenServer.reply(from, :ok)
      %{state | waiting: []}
    else
      state
    end
  end

  defp release(state), do: state

  # Starts what may start: up to `concurrency` at a time, and at most
  # `per_minute` a minute for each service. A request over its service's
  # limit waits, and the ones behind it for other services go ahead.
  defp pump(state) do
    concurrency = Keyword.get(config(), :concurrency, 4)
    now = System.monotonic_time(:millisecond)
    sent = Map.new(state.sent, fn {s, times} -> {s, Enum.filter(times, &(now - &1 < 60_000))} end)
    state = %{state | sent: sent}

    {state, held} = start_due(state, concurrency, now, [])
    state = %{state | queue: :queue.join(:queue.from_list(held), state.queue)}

    if held != [] and state.timer == nil,
      do: %{state | timer: Process.send_after(self(), :pump, 1000)},
      else: state
  end

  defp start_due(state, concurrency, now, held) do
    if map_size(state.running) >= concurrency do
      {state, Enum.reverse(held)}
    else
      case :queue.out(state.queue) do
        {:empty, _} ->
          {state, Enum.reverse(held)}

        {{:value, request}, rest} ->
          state = %{state | queue: rest}
          times = Map.get(state.sent, request.service, [])

          if length(times) >= Keyword.get(config(), :per_minute, 120) do
            start_due(state, concurrency, now, [request | held])
          else
            task =
              Task.Supervisor.async_nolink(Theseus.TaskSupervisor, fn ->
                request |> perform() |> deliver()
              end)

            state = %{
              state
              | running: Map.put(state.running, task.ref, request),
                sent: Map.put(state.sent, request.service, [now | times])
            }

            start_due(state, concurrency, now, held)
          end
      end
    end
  end

  # Sending ---------------------------------------------------------------

  defp perform(request) do
    service = Services.get(request.service)

    with {:ok, url} <- url(request, service),
         {:ok, token} <- token(service, request) do
      attempt(request, url, token, 1)
    else
      {:error, why} -> response(request, nil, %{}, nil, why)
    end
  end

  defp token(%{connect: nil}, _request), do: {:ok, nil}

  defp token(service, %{domain: nil}),
    do: {:error, "a request to #{service.name} names the domain whose connection to use"}

  defp token(service, request), do: Connections.token(service.name, request.domain)

  defp attempt(request, url, token, n) do
    headers =
      Enum.to_list(request.headers) ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: [])

    body =
      case request.body do
        nil -> nil
        text when is_binary(text) -> {request.headers["content-type"], text}
        data -> {"application/json", JSON.encode!(data)}
      end

    timeout = Keyword.get(config(), :timeout_ms, 30_000)
    result = HTTP.send_request(request.method, url, headers, body, timeout: timeout)
    if request.domain, do: Connections.used(request.service, request.domain, status_of(result))

    case result do
      {:ok, 401, _h, _b} when token != nil and n == 1 ->
        case Connections.token(request.service, request.domain, renew: true) do
          {:ok, renewed} -> attempt(request, url, renewed, 2)
          {:error, why} -> response(request, 401, %{}, nil, why)
        end

      {:ok, status, response_headers, response_body} ->
        if retry?(request, status, n) do
          Process.sleep(delay(n, response_headers))
          attempt(request, url, token, n + 1)
        else
          answer(request, status, response_headers, response_body)
        end

      {:error, reason} ->
        if retry?(request, nil, n) do
          Process.sleep(delay(n, []))
          attempt(request, url, token, n + 1)
        else
          response(request, nil, %{}, nil, "no answer (#{inspect(reason, limit: 3)})")
        end
    end
  end

  defp status_of({:ok, status, _h, _b}), do: status
  defp status_of({:error, _reason}), do: "no answer"

  # Only a GET is tried again: another method may have done its work.
  defp retry?(%{method: "GET"}, status, n) when n < 3,
    do: status == nil or status == 429 or status >= 500

  defp retry?(_request, _status, _n), do: false

  defp delay(n, headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, seconds} ->
        case Integer.parse(seconds) do
          {s, ""} when s >= 0 and s <= 30 -> s * 1000
          _ -> if n == 1, do: 1000, else: 5000
        end

      nil ->
        if n == 1, do: 1000, else: 5000
    end
  end

  defp answer(request, status, headers, body) do
    max = Keyword.get(config(), :max_body_bytes, 10_000_000)
    headers = for {k, v} <- headers, k != "set-cookie", into: %{}, do: {k, v}
    json? = String.contains?(headers["content-type"] || "", "json")

    cond do
      byte_size(body) > max ->
        response(request, status, headers, nil, "the answer is over #{max} bytes")

      json? and body != "" ->
        case JSON.decode(body) do
          {:ok, data} -> response(request, status, headers, data, nil)
          {:error, _} -> response(request, status, headers, body, "the answer is not valid JSON")
        end

      String.valid?(body) ->
        response(request, status, headers, body, nil)

      true ->
        response(
          request,
          status,
          headers,
          nil,
          "the answer is not text (#{byte_size(body)} bytes)"
        )
    end
  end

  defp response(request, status, headers, body, error) do
    %{
      request: request,
      status: status,
      headers: headers,
      body: body,
      error: error,
      now: DateTime.utc_now(),
      id: Effects.new_id()
    }
  end

  defp deliver(response) do
    case Effects.callback(:fetched, response) do
      {:ok, _} -> :ok
      :none -> Logger.warning("the app made a request but has no fetched/1 to take its answer")
      {:error, why} -> Logger.warning("the app's fetched/1 failed: #{why}")
    end
  end
end
