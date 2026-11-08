# Theseus

Theseus runs an Elixir application whose whole code lives in one ledger file. Nobody edits source files. You ask your coding agent (Claude Code, Codex, any MCP client) for a change; the agent reads and proposes units over MCP; Theseus validates each proposal against its spec, against recorded real calls and against live calls, and holds it; you approve it on a review page that shows behaviour, never code. Approved changes load into the running app without a restart. In production, Theseus also repairs crashes on its own.

`PLAN.md` is the design and the record of every decision. This file is how to run it.

## Run an app

Elixir 1.20 and OTP 29.

```bash
THESEUS_LEDGER=myapp.theseus mix run --no-halt
```

- The app answers on http://localhost:4000 (`PORT`).
- The review page and the MCP endpoint are on http://127.0.0.1:4001 (`ADMIN_PORT`). The log prints a reviewer link with a token; open it once to approve and reject.
- A new ledger is an empty app. It answers "this app has no endpoint unit yet" until an agent creates one.

Next to the ledger, Theseus keeps `myapp.theseus.traces` (recorded calls), `.state` (server units' state), `.connections` (Google Workspace connections) and `.outbox` (messages the app sent), each encrypted. The keys are in `~/.config/theseus/`, created on first run. Only one instance can open a ledger: a second refuses to start and says which process has it open, through `myapp.theseus.lock`.

The ledger only grows while the app runs. To shrink it, stop the app and run:

```bash
THESEUS_LEDGER=myapp.theseus mix theseus.compact --keep 5 --days 30
```

Each module keeps its last 5 versions and every version a branch or pending change uses; older versions lose their code. Changes decided more than 30 days ago lose their code and keep a short summary of each check. Every event stays, so history, branches and rollbacks to kept versions work as before. The old file is kept as `myapp.theseus.archive-<time>`; delete it when you no longer need it. `--dry-run` reports what would go and changes nothing.

An app keeps its records in Postgres (see [docs/database-design.md](docs/database-design.md)). Set `THESEUS_DATABASE_URL` to a database Theseus may create tables in; each app gets its own Postgres schema, named after the ledger file unless `THESEUS_DATABASE_SCHEMA` says otherwise. For development, a separate container works:

```bash
docker run -d --name theseus-pg -p 127.0.0.1:5442:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17
```

```bash
psql -h 127.0.0.1 -p 5442 -U postgres -c "create database theseus_dev" -c "create database theseus_test"
```

```bash
THESEUS_DATABASE_URL=postgres://postgres@127.0.0.1:5442/theseus_dev THESEUS_LEDGER=myapp.theseus mix run --no-halt
```

Without the variable the app has no tables, and works as before. The tests use `postgres://postgres@127.0.0.1:5442/theseus_test` (`THESEUS_TEST_DATABASE_URL`) and leave out the Postgres tests when it cannot be reached.

Messages the app sends, such as email, are held on the review site's Outbox page. To send them, set `THESEUS_OUTBOX_WEBHOOK` to a URL that takes each message as JSON (and `THESEUS_OUTBOX_TOKEN` to send a bearer token).

The review site shows behaviour, never code:

- Dashboard: changes waiting for you, crashes, the units, recent decisions and history.
- A change: what it is for, its checks, how recorded calls behave before and after (for a group, the root endpoint's replay comes first as "What people see"), and its spec changes in plain sentences.
- History, Branches (with previews of a branch on its own port), Routes (every path the app answers and which unit answers it), Connections and Outbox.

Working as a team: by default the review site uses the one-time reviewer link printed at start, and the MCP endpoint is open to this machine. Set `THESEUS_REVIEW_ISSUER` (an OpenID Connect provider, such as `https://accounts.google.com`), `THESEUS_REVIEW_CLIENT_ID`, `THESEUS_REVIEW_CLIENT_SECRET` and `THESEUS_REVIEW_URL` (the site's address; the provider's redirect address is this plus `/sign-in/callback`) to turn on team mode:

- People sign in to the review site. The first is an admin, who adds the others on the Team page (or set `THESEUS_REVIEW_DOMAINS` to let a domain's people in as engineers). Roles are engineer, reviewer and admin.
- Each person makes MCP tokens on the review site, and an agent sends one as a bearer token. A token can be tied to a branch.
- On the live branch, a reviewer or admin other than the proposer approves. Engineers approve their own changes on branches they created. Units can have owners, who approve their spec, schema and merge changes; an admin may approve anyway with a reason, which the ledger records.
- `ADMIN_IP` may bind the admin port beyond 127.0.0.1, normally behind a proxy that serves it over TLS. With `THESEUS_PREVIEW_DOMAIN` set, previews are reached at `<branch>.<domain>` through the admin port, by team members only.

In team mode the engine also sends notices through the outbox: a change waiting for you, your change combined with another or needing proposing again, your branch's parent changing a unit it changes, and a crash starting a repair. Validations share the sandboxes in turn between people (`validation: [slots: n]`), and at most four previews run at once (`previews: [max: n]`).

Previews use made-up data from the app's seed units (`Theseus.Seed`), kept in memory. `THESEUS_PREVIEW_DATA=production` makes them read the app's database instead, keeping none of their writes.

Pages can use htmx to replace part of a page. The engine serves htmx 2.0.4 at `/_theseus/htmx-2.0.4.min.js`. The agent instructions say how: htmx requests reach the endpoint unit with an `htmx` key, units set htmx response headers with `{:htmx, headers, response}`, and a redirect answering an htmx request becomes `HX-Redirect`.

Connect Claude Code:

```bash
claude mcp add --transport http theseus http://127.0.0.1:4001/mcp
```

Then ask for what you want ("add a page that lists ..."). The agent gets the rules from the MCP server.

## Sign-in and connections

Apps can sign people in with Google and connect a Google Workspace directory (PLAN.md 7.15, 7.18, 7.25).

### Without Google

A fake Google on this machine agrees to everything and lists seven made-up Workspace users and four groups. Its directory changes as it is synced: on the second sync Hana Kim joins, and on the third Bob Ross is suspended.

```bash
mix theseus.fake_google
```

```bash
THESEUS_LEDGER=app.theseus THESEUS_FAKE_GOOGLE=http://127.0.0.1:4999 THESEUS_DEV_SIGN_IN=1 mix run --no-halt
```

Open http://localhost:4000. "Sign in with Google" signs you in as ada@example.com. http://localhost:4000/auth/dev signs you in as anyone. The fake keeps its tokens in memory, so connect again after restarting it.

### With Google

1. In Google Cloud Console, create an OAuth client of type "Web application" with the redirect URI `http://localhost:4000/auth/google/callback`. For the directory, enable the Admin SDK API in the same project, and add the scopes `https://www.googleapis.com/auth/admin.directory.user.readonly` and, for groups, `https://www.googleapis.com/auth/admin.directory.group.readonly` to the consent screen. An "Internal" consent screen needs no review.
2. Start the app with the client:

```bash
THESEUS_LEDGER=app.theseus GOOGLE_CLIENT_ID=your-client-id GOOGLE_CLIENT_SECRET=your-client-secret mix run --no-halt
```

`GOOGLE_HOSTED_DOMAIN=example.com` limits sign-in to one Workspace. `GOOGLE_REDIRECT_URL` reuses another redirect URL; Theseus takes the callback on its path. Open the app at http://localhost:4000, not 127.0.0.1, so the session cookie survives the trip to Google.

## Tests

```bash
mix test
```

The tests never call a model or Google.

Theseus uses a model to repair crashes, to rewrite units that changed many times, and to read new spec rules against their sentences. `THESEUS_LLM` picks the provider and `THESEUS_MODEL` the model:

- `openai` (the default): set `OPENAI_API_KEY`. Default model `gpt-6.1-sol`.
- `anthropic`: set `ANTHROPIC_API_KEY`. Default model `claude-opus-5-5`.
- `openai_compatible`: any server with an OpenAI-style `/chat/completions` endpoint, such as Ollama or vLLM. Set `THESEUS_LLM_URL` (for example `http://localhost:11434/v1`) and `THESEUS_MODEL`, and `THESEUS_LLM_API_KEY` if the server needs a key.

Each call waits at most 180 seconds; `THESEUS_LLM_TIMEOUT_MS` changes that, for a local model that writes slowly. With Ollama, raise its context length (for example `OLLAMA_CONTEXT_LENGTH=32768`): it cuts off a longer prompt without an error.

Personal data in what it sends is replaced. Without a model, crashes are recorded and wait for a person, and the other two do not run.
