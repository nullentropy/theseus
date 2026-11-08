defmodule Mix.Tasks.Theseus.Import do
  @shortdoc "Registers units and specs from a directory of .ex files into the ledger"
  @moduledoc """
      mix theseus.import test/fixtures/sample

  Starts the app against its ledger (`THESEUS_LEDGER` or config
  `:ledger_path`), registers every module in the directory, and prints the
  result. Modules already in the ledger are skipped.
  """

  use Mix.Task

  @impl true
  def run([dir]) do
    Application.put_env(:theseus, :app, Keyword.put(app_config(), :server, false))
    Application.put_env(:theseus, :admin, Keyword.put(admin_config(), :server, false))
    Mix.Task.run("app.start")

    for {module, result} <- Theseus.Import.dir(dir) do
      case result do
        {:ok, hash} ->
          Mix.shell().info("registered #{inspect(module)} #{Theseus.Version.short(hash)}")

        {:error, :already_registered} ->
          Mix.shell().info("skipped #{inspect(module)}: already registered")

        {:error, reason} ->
          Mix.shell().error("failed #{inspect(module)}: #{inspect(reason)}")
      end
    end

    Mix.shell().info("ledger: #{Theseus.Ledger.path()}")
  end

  def run(_), do: Mix.raise("usage: mix theseus.import DIR")

  defp app_config, do: Application.get_env(:theseus, :app, [])
  defp admin_config, do: Application.get_env(:theseus, :admin, [])
end
