defmodule LokiLoggerHandler.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LokiLoggerHandler.InstanceSupervisor
    ]

    opts = [strategy: :one_for_one, name: LokiLoggerHandler.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
