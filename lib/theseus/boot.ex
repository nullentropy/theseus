defmodule Theseus.Boot do
  @moduledoc """
  Runs once at startup, before the application's own supervisor starts:
  rebuilds every unit and spec from the ledger. The boot fails if any
  version's hash does not match its AST.
  """

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :transient}
  end

  @doc false
  def start_link do
    case run() do
      :ok -> :ignore
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run() :: :ok | {:error, term()}
  def run do
    Theseus.Branches.refresh_live()

    case for({module, {:error, reason}} <- Theseus.Loader.rebuild(), do: {module, reason}) do
      [] -> :ok
      failures -> {:error, {:rebuild_failed, failures}}
    end
  end
end
