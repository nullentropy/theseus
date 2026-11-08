defmodule Theseus.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Theseus.Leader, Theseus.Supervisor, Theseus.App]
    Supervisor.start_link(children, strategy: :rest_for_one, name: Theseus.AppSupervisor)
  end
end
