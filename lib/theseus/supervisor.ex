defmodule Theseus.Supervisor do
  @moduledoc """
  Supervises everything under `Theseus.*`. The order matters: a crash
  restarts every later child, and `Theseus.Boot` rebuilds the registry from
  the ledger.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # On a follower (see Theseus.Leader) the units run and the app's
    # requests are served; the children marked `only` run on the leader only.
    children = [
      Theseus.Ledger,
      Theseus.Registry,
      Theseus.Traces,
      {Task.Supervisor, name: Theseus.TaskSupervisor},
      only(Theseus.Queue),
      Theseus.Loader,
      Theseus.Boot,
      # The app's tables are created once the units are back.
      Theseus.Store.DB,
      only(Theseus.Servers),
      only(Theseus.Shadow),
      only(Theseus.Changes),
      only(Theseus.LLM.Log),
      only({Task.Supervisor, name: Theseus.ProposerSupervisor}),
      only(Theseus.Trigger),
      only(Theseus.Consolidate),
      only(Theseus.Combine),
      only(Theseus.Previews),
      only(Theseus.Outbox),
      only(Theseus.Connections),
      only(Theseus.Fetch),
      only(Theseus.Clients),
      only(Theseus.Team),
      only(Theseus.Ticker),
      Theseus.Admin,
      # Last, so it stops first and saves server units' state while they run.
      only(Theseus.State)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp only(child), do: Theseus.Leader.only(child)
end
