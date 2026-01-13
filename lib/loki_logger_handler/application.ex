defmodule LokiLoggerHandler.Application do
  @moduledoc false

  use Supervisor

  def start(_type, _args) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: LokiLoggerHandler.Registry},
      {DynamicSupervisor, name: LokiLoggerHandler.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Returns the via tuple for Registry lookup.
  # Used by Storage and Sender modules to register and lookup processes.
  @doc false
  def via(module, handler_id) do
    {:via, Registry, {LokiLoggerHandler.Registry, {module, handler_id}}}
  end
end
