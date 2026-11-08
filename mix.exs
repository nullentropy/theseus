defmodule Theseus.MixProject do
  use Mix.Project

  def project do
    [
      app: :theseus,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # The sample's starting units are imported into the ledger, not tests.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key],
      mod: {Theseus.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.14"},
      {:plug, "~> 1.20"},
      {:postgrex, "~> 0.21"},
      {:stream_data, "~> 1.4"},
      {:telemetry, "~> 1.4"}
    ]
  end

  # Each test run starts from an empty ledger, trace file and trace key.
  defp aliases do
    [test: [fn _ -> Enum.each(Path.wildcard("tmp/test*"), &File.rm_rf!/1) end, "test"]]
  end
end
