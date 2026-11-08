import Config

config :theseus,
  ledger_path: Path.expand("../tmp/test.theseus", __DIR__),
  trace_key_path: Path.expand("../tmp/test_trace.key", __DIR__),
  session_key_path: Path.expand("../tmp/test_session.key", __DIR__),
  state_key_path: Path.expand("../tmp/test_state.key", __DIR__),
  # Turned on by the tests that need it.
  state_file: false,
  connections_file: false,
  # Engine records stay in files in tests, even with the test database.
  records: :files,
  clients_file: false,
  team_file: false,
  previews_file: false,
  outbox_file: false,
  drain_ms: 200,
  stage_timeout_ms: 5_000,
  shadow_calls: 10,
  shadow_ms: 300

# Tests never call a real model. Crash repair is turned on per test.
config :theseus, :llm, module: Theseus.LLM.Stub, rule_check: false

config :theseus, :crash_repair,
  enabled: false,
  window_ms: 50,
  watch_ms: 1_000

config :theseus, :consolidate, enabled: false

config :theseus, :admin, server: false
config :theseus, :app, server: false, tick_seconds: 0

config :logger, level: :warning

# The store's tests need Postgres; without it they are skipped. See README.
config :theseus, :store,
  url:
    System.get_env("THESEUS_TEST_DATABASE_URL", "postgres://postgres@127.0.0.1:5442/theseus_test"),
  schema: "theseus_test",
  pool_size: 5

# Previews look for branch changes often, so tests need not wait.
config :theseus, :previews, follow_ms: 200

# Combining runs after approvals, in the background; its tests turn it on.
config :theseus, :combine, enabled: false
