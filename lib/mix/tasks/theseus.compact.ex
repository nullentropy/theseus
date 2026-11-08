defmodule Mix.Tasks.Theseus.Compact do
  @shortdoc "Compacts a ledger no app has open"
  @moduledoc """
      mix theseus.compact [--keep 5] [--days 30] [--ledger PATH] [--dry-run]

  Compacts the ledger (`--ledger`, else `THESEUS_LEDGER` or config
  `:ledger_path`). Each module keeps its last `--keep` versions whole, plus
  every version a branch, merge or pending change uses. Changes decided
  more than `--days` days ago lose their code and keep a short summary of
  each check. See `Theseus.Compact`.

  A running app compacts its own ledger, on its own or with
  `Theseus.compact/1` in its shell; this task refuses a ledger an app has
  open. What a run takes out goes to the archive (`<ledger>.archive`, or
  the table `_theseus_ledger_archive`). `--dry-run` reports what would go
  and changes nothing.
  """

  use Mix.Task

  @switches [keep: :integer, days: :integer, ledger: :string, dry_run: :boolean]

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        # Config only: the app must not start, or it would open the ledger.
        Mix.Task.run("app.config")
        path = opts[:ledger] || Application.fetch_env!(:theseus, :ledger_path)

        case Theseus.Compact.run(path, Keyword.take(opts, [:keep, :days, :dry_run])) do
          {:ok, stats} -> Mix.shell().info(Theseus.Compact.report(stats))
          {:error, message} -> Mix.raise(message)
        end

      _ ->
        Mix.raise("usage: mix theseus.compact [--keep 5] [--days 30] [--ledger PATH] [--dry-run]")
    end
  end
end
