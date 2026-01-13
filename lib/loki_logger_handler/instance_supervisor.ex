defmodule LokiLoggerHandler.InstanceSupervisor do
  @moduledoc """
  DynamicSupervisor for managing handler instance processes.

  Each handler instance (identified by handler_id) has its own Storage and Sender
  processes. These are started dynamically when a handler is attached and stopped
  when the handler is removed.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
