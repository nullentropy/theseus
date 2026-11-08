import Config

# For demos without Google: THESEUS_FAKE_GOOGLE=http://127.0.0.1:4999 sends
# the requests an app makes to Google's sign-in, token and Admin SDK
# addresses to a local fake Google instead (mix theseus.fake_google), and
# gives the app's `google` service a fake OAuth client. Every Google
# address the app declares must be rewritten here, or the fake token goes
# to the real Google. Development only; never set in production.
if url = System.get_env("THESEUS_FAKE_GOOGLE") do
  url = String.trim_trailing(url, "/")

  config :theseus, :http,
    rewrite: [
      # The fake's own path for it, which older fakes also answer.
      {"https://accounts.google.com/o/oauth2/v2/auth", url <> "/authorize"},
      {"https://accounts.google.com/", url <> "/"},
      {"https://oauth2.googleapis.com/", url <> "/"},
      {"https://admin.googleapis.com/", url <> "/"}
    ]

  config :theseus, :clients, %{
    "google" => [client_id: "fake-client", client_secret: "fake-secret"]
  }
end
