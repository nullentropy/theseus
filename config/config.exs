import Config

root = Path.expand("..", __DIR__)

config :theseus,
  # The application: one ledger file. Override with THESEUS_LEDGER.
  ledger_path: Path.join(root, "app.theseus"),
  trace_buffer: 500,
  # Distinct failing calls kept per unit beyond the ring buffer.
  failing_traces: 200,
  # Recorded calls are kept in an encrypted file next to the ledger
  # (<ledger>.traces, or THESEUS_TRACES). The key is THESEUS_TRACE_KEY, or a
  # key file created on first use at ~/.config/theseus/trace.key.
  trace_file: true,
  # Server units' state is kept in an encrypted file next to the ledger
  # (<ledger>.state), so it survives restarts. The key is THESEUS_STATE_KEY,
  # or a key file created on first use at ~/.config/theseus/state.key.
  state_file: true,
  # Messages the app sends are kept in an encrypted file next to the ledger
  # (<ledger>.outbox), with the state key. See Theseus.Outbox.
  outbox_file: true,
  # How long a promote waits for processes to leave old code before purging.
  drain_ms: 5_000,
  # Per-stage validation timeout.
  stage_timeout_ms: 30_000,
  # A proposed change runs beside the live unit for this many live calls or
  # this long, whichever comes first, before a person is asked to decide.
  shadow_calls: 50,
  shadow_ms: 60_000

# The model the in-process proposer uses for crash repair. The API key is
# read from OPENAI_API_KEY when needed; THESEUS_MODEL sets the model.
config :theseus, :llm,
  module: Theseus.LLM.OpenAI,
  model: "gpt-6.1-sol",
  # Recorded calls in prompts get email addresses and name fields replaced.
  redact_personal: true,
  # The model reads each new or changed spec rule and says whether its code
  # checks what its sentence says (Theseus.RuleCheck).
  rule_check: true

# Crash repair (production mode). Runs only when the model is available.
config :theseus, :crash_repair,
  enabled: true,
  # How long the first crash of a kind collects more failing calls.
  window_ms: 10_000,
  max_attempts: 2,
  runs_per_minute: 3,
  # How long a promoted fix is watched for the same crash.
  watch_ms: 300_000,
  # Fixes larger than this are held for a person.
  max_diff_lines: 40,
  # A fix whose shadow run saw no live calls goes on replay alone when
  # recorded calls reproduced the crash and now work.
  without_traffic: false,
  # Fixes to server units, which hold state, are promoted without a person.
  server_units: false,
  gate: Theseus.Gate.AutoBounded

# Consolidation: a unit with more than `after` promoted changes since it was
# last rewritten is rewritten cleanly, with the same behaviour, once no
# change has arrived for `quiet_ms`. Needs the model above.
config :theseus, :consolidate,
  enabled: true,
  after: 10,
  quiet_ms: 60_000

# MCP server and review page. Bound to 127.0.0.1; in team mode `ip:`
# (ADMIN_IP) may name another address (Theseus.Admin).
config :theseus, :admin,
  server: true,
  port: 4001

# The application's HTTP server. It passes every request to the app's
# endpoint unit (see Theseus.Endpoint). public_url (PUBLIC_URL) is the URL
# people use to reach it; it defaults to http://localhost:<port>.
config :theseus, :app,
  server: true,
  port: 4000,
  # The endpoint unit's optional tick/1 runs this often (Theseus.Ticker).
  tick_seconds: 60

# Sign-in (see Theseus.SignIn), with the services the app declares
# (Theseus.Services); each needs NAME_CLIENT_ID and NAME_CLIENT_SECRET.
# Sessions are kept in a cookie encrypted with the session key
# (THESEUS_SESSION_KEY, or ~/.config/theseus/session.key). THESEUS_DEV_SIGN_IN=1
# turns on a sign-in form for any email, usable only from this machine.
config :theseus, :sign_in,
  session_hours: 12,
  dev: false

# Requests the app makes to the services it declares (Theseus.Fetch), with
# the tokens of the connections admins make (Theseus.Connections, kept in an
# encrypted file next to the ledger, <ledger>.connections).
config :theseus, :fetch, concurrency: 4, per_minute: 120

import_config "#{config_env()}.exs"
