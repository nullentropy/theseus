defmodule Theseus.Endpoint do
  @moduledoc """
  An endpoint unit is the application's HTTP interface, kept in the ledger
  like any other unit. Theseus's HTTP server (`Theseus.Web`) passes every
  request on the app port to it, except the sign-in requests the engine
  handles itself (`Theseus.SignIn`).

      defmodule Toy.Routes do
        use Theseus.Endpoint

        def handle(%{method: "POST", path: ["split"], body: body}) do
          case Theseus.call(Toy.TipSplit, :split, [body["bill"], body["tip"], body["people"]]) do
            {:ok, shares} -> {200, %{shares: shares}}
            {:error, reason} -> {422, %{error: inspect(reason)}}
          end
        end

        def handle(%{method: "GET", path: [], user: nil}), do: {:redirect, "/login"}

        def handle(_request), do: {404, %{error: "not found"}}
      end

  The request is a map with these keys, always all present, and `htmx`
  for htmx requests:

    * `method`: "GET", "POST" and so on.
    * `path`: the path as segments, `["coupons", "SAVE10"]`.
    * `query`: the query string, `%{"k" => "v"}`.
    * `body`: a JSON or form body decoded to a map (a JSON value that is
      not an object is under `"_json"`); any other body as a string. Headers and cookies are not passed.
    * `user`: the signed-in user (see `sign_in/1`), or nil.
    * `csrf_token`: the token a signed-in page puts in its forms as a hidden
      `_csrf` field, or nil.
    * `now`: the time of the request, a `DateTime`. Units are deterministic,
      so they take the time from here, never from the clock.
    * `id`: random, recorded with the call; new rows take their ids from it
      (`Theseus.Store.id/2`), so a replayed request creates the same ones.
    * `client`: only for a request from an API client with a bearer token
      (`Theseus.ClientAuth`): `%{id, name}`. `user` is then the person who
      let the client act as them, and `csrf_token` is nil.
    * `htmx`: only when htmx asks for part of a page (an `HX-Request`
      header, but not a boosted link or form, nor a history restore, which
      want the whole page): `%{target, trigger, trigger_name, current_path,
      prompt}`, each a string or nil, as the browser sent them. `target` is
      the id of the element the answer goes into. Match it in a clause
      before the whole-page clause, or read `request[:htmx]`.

  `handle/1` returns `{status, body}` for a JSON response, `{status, :html,
  html}` for a page, `{status, :text, text}`, or `{:redirect, "/path"}`
  for a redirect within the site, or `{status, {:download, "name.csv",
  "text/csv"}, data}` for a file to save (CSV, plain text or JSON). Text
  from users goes into HTML through `Plug.HTML.html_escape/1`.

  A form posted as `multipart/form-data` may carry files. The engine keeps
  each one and puts a reference in the body instead, `%{"file" => id,
  "name", "type", "size"}`; keep the reference in a table. Answer
  `{status, {:upload, id}}` to send a kept file back (see `Theseus.Files`).

  To set htmx response headers, `handle/1` returns `{:htmx, headers,
  response}`, where `headers` is a map or keyword list of any of `trigger`
  (an event name, or a map of event names to JSON details),
  `trigger_after_settle`, `trigger_after_swap`, `retarget`, `reswap`,
  `reselect` (strings), `push_url`, `replace_url` (a path on this site, or
  false), `redirect`, `location` (a path on this site) and `refresh: true`
  (see `Theseus.Web.htmx_headers/1`). A `{:redirect, "/path"}` that answers
  an htmx request is sent as `HX-Redirect` with status 200, so the browser
  loads the whole next page instead of htmx putting it into the target.
  Every answer carries `Vary: HX-Request`.

  Boosted links and forms (`hx-boost`) reach the unit as plain requests.
  For them the engine sends a download back as `HX-Redirect` to the same
  GET, so the browser fetches it as a file; sends its own redirects to a
  sign-in service as `HX-Redirect`; and keeps the address bar when a form
  answers with a page (its errors, say) instead of a redirect.

  The app's data lives in Postgres tables declared in schema units (see
  `Theseus.Schema` and `Theseus.Store`). Endpoint units read with
  `Theseus.Store.get/2`, `all/2` and `count/2`, and return their writes
  around their result: `{:write, [{:insert, :notes, row}], result}`. New
  ids come from `Theseus.Store.id(request, n)`; every request, and the
  argument of `tick/1`, `connection/1` and `fetched/1`, has an `id` for
  this, and a sign-in identity gives ids from the whole of it.

  To send messages such as email, any callback returns `{:send, messages,
  result}` instead of `result`, where each message is `%{to: address or
  [addresses], subject: text, text: text}` with an optional `link: "/path"`
  in the app. The engine queues them (`Theseus.Outbox`) and carries on
  with `result`. Validation compares them like the rest of the result and
  never sends them.

  `sign_in/1` is optional. The engine calls it when someone has proved who
  they are, with `%{provider, id, email, name, first_name, last_name,
  picture, domain, now}`. It returns `{:ok, user}` to let them in, with the
  small map every later request carries as `user`, or `{:error, response}`
  to turn them away with that response.

  Units never reach the network. The outside services the app uses are
  declared in a services unit (`Theseus.Services`). To call one, any
  callback returns `{:fetch, requests, result}` around its result; the
  engine sends the requests after the call commits and calls `fetched/1`
  with each response (`Theseus.Fetch`). `allow?/1` gets `%{action,
  service, domain, user, now}` and returns true to let the signed-in user
  connect or disconnect a service for a domain; `connection/1` hears that
  it happened (`Theseus.Connections`). All three are optional.

  An app can offer an API, an MCP server for example, to clients acting for
  its users: the engine runs the OAuth flow those clients expect and passes
  their requests on with `user` and `client` set (`Theseus.ClientAuth`).
  Answer 401 to a request that needs a person and has none; the engine adds
  the header that tells a client where to get a token.

  `tick/1` is optional. The engine calls it every minute with `%{now,
  last}` so the app can do scheduled work without reading the clock (see
  `Theseus.Ticker`).

  An app can split its routes across several endpoint units. The engine
  sends every request, and calls every other callback, on the root: the endpoint unit that no other unit calls. The root hands
  requests on to the others with `Theseus.call(Other, :handle, [request])`.

  An endpoint unit calls other units only through `Theseus.call/3`, so those
  calls are recorded, replayed and repaired like any other. It may not call
  them directly. Endpoint units are validated on the sandbox node with every
  unit of their branch loaded and server units started fresh, and
  replayed. One that calls only pure units is also shadowed on live
  requests, reading the data each request read (see `Theseus.Shadow`); one
  that calls a server unit is not, since a second handler would call it
  twice.
  """

  @type request :: %{
          optional(:htmx) => %{
            target: String.t() | nil,
            trigger: String.t() | nil,
            trigger_name: String.t() | nil,
            current_path: String.t() | nil,
            prompt: String.t() | nil
          },
          method: String.t(),
          path: [String.t()],
          query: %{String.t() => String.t()},
          body: map() | String.t(),
          user: term(),
          csrf_token: String.t() | nil,
          now: DateTime.t(),
          id: String.t()
        }

  @type response ::
          {pos_integer(), term()}
          | {pos_integer(), :html | :text, String.t()}
          | {pos_integer(), {:download, String.t(), String.t()}, binary()}
          | {:redirect, String.t()}
          | {:send, [map()], term()}
          | {:htmx, map() | keyword(), term()}
          | {:write, [tuple()], term()}
          | {:fetch, [map()], term()}

  @callback handle(request()) :: response()
  @callback sign_in(identity :: map()) :: {:ok, term()} | {:error, response()}
  @callback allow?(request :: map()) :: boolean()
  @callback connection(event :: map()) :: term()
  @callback fetched(response :: map()) :: term()
  @callback tick(%{now: DateTime.t(), last: DateTime.t() | nil}) :: term()
  @optional_callbacks sign_in: 1, allow?: 1, connection: 1, fetched: 1, tick: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Theseus.Endpoint
    end
  end
end
