# Each run starts from an empty ledger (see the test alias in mix.exs).
for {module, {:error, reason}} <- Theseus.Import.dir("test/fixtures/sample") do
  raise "could not import #{inspect(module)}: #{inspect(reason)}"
end

# The store's tests run against Postgres (config :theseus, :store), in a
# schema emptied for each run. Without a database they are left out.
store =
  if Theseus.Store.DB.configured?() do
    try do
      Postgrex.query!(Theseus.Store.Pool, "DROP SCHEMA IF EXISTS theseus_test CASCADE", [])
      :ok
    rescue
      e -> {:skip, Exception.message(e)}
    end
  else
    {:skip, "no database configured"}
  end

case store do
  :ok ->
    ExUnit.start()

  {:skip, why} ->
    IO.puts("Skipping the store's Postgres tests: #{String.slice(why, 0, 200)}")
    ExUnit.start(exclude: [:postgres])
end
