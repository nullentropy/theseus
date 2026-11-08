import Config

if path = System.get_env("THESEUS_LEDGER") do
  config :theseus, ledger_path: Path.expand(path)
end

if path = System.get_env("THESEUS_TRACES") do
  config :theseus, trace_path: Path.expand(path)
end

if model = System.get_env("THESEUS_MODEL") do
  config :theseus, :llm, model: model
end

if provider = System.get_env("THESEUS_LLM") do
  config :theseus, :llm, provider: provider
end

if url = System.get_env("THESEUS_LLM_URL") do
  config :theseus, :llm, base_url: url
end

if ms = System.get_env("THESEUS_LLM_TIMEOUT_MS") do
  config :theseus, :llm, timeout_ms: String.to_integer(ms)
end

if System.get_env("THESEUS_CRASH_REPAIR") in ["off", "false", "0"] do
  config :theseus, :crash_repair, enabled: false
end

if port = System.get_env("PORT") do
  config :theseus, :app, port: String.to_integer(port)
end

if port = System.get_env("ADMIN_PORT") do
  config :theseus, :admin, port: String.to_integer(port)
end

if ip = System.get_env("ADMIN_IP") do
  {:ok, address} = :inet.parse_address(String.to_charlist(ip))
  config :theseus, :admin, ip: address
end

# The app's data (Theseus.Store): a Postgres database, such as
# postgres://user:password@localhost:5432/theseus. THESEUS_DATABASE_SCHEMA
# names the Postgres schema for the app's tables (default: the ledger's name).
database_url = System.get_env("THESEUS_DATABASE_URL")

if config_env() != :test and database_url not in [nil, ""] do
  config :theseus, :store,
    url: database_url,
    schema: System.get_env("THESEUS_DATABASE_SCHEMA")
end

# Previews use made-up data from the seed units unless this says
# "production" (Theseus.Previews).
if System.get_env("THESEUS_PREVIEW_DATA") == "production" do
  config :theseus, :previews, data: :production
end

if url = System.get_env("PUBLIC_URL") do
  config :theseus, :app, public_url: url
end

# A service's OAuth client (NAME_CLIENT_ID, NAME_CLIENT_SECRET and
# NAME_REDIRECT_URL) is read from the environment when it is used; see
# Theseus.OAuth.

if minutes = System.get_env("THESEUS_IDLE_MINUTES") do
  config :theseus, :sign_in, idle_minutes: String.to_integer(minutes)
end

# Dev sign-in trusts requests from 127.0.0.1, which behind a reverse proxy
# is every request, so production builds ignore it.
if config_env() != :prod and System.get_env("THESEUS_DEV_SIGN_IN") in ["1", "true", "on"] do
  config :theseus, :sign_in, dev: true
end

# Messages the app sends are held on the review page unless a webhook is set
# (Theseus.Outbox).
# Tests never send.
webhook = System.get_env("THESEUS_OUTBOX_WEBHOOK")

if config_env() != :test and webhook not in [nil, ""] do
  config :theseus, :outbox,
    adapter: :webhook,
    url: webhook,
    token: System.get_env("THESEUS_OUTBOX_TOKEN")
end
