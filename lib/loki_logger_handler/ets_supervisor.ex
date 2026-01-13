defmodule LokiLoggerHandler.EtsSupervisor do
  # Supervisor for a handler instance's ETS Storage and Sender processes.
  #
  # Each handler instance using memory storage gets its own EtsSupervisor which
  # supervises both the Storage.Ets and Sender processes together.
  #
  # Uses auto_shutdown: :all_significant so that when both children exit,
  # the supervisor itself exits cleanly.

  @moduledoc false

  use Supervisor

  alias LokiLoggerHandler.Storage.Ets
  alias LokiLoggerHandler.Sender

  @doc false
  def start_link(opts) do
    handler_id = Keyword.fetch!(opts, :handler_id)
    name = supervisor_name(handler_id)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    handler_id = Keyword.fetch!(opts, :handler_id)

    storage_opts = [
      name: storage_name(handler_id),
      max_buffer_size: Keyword.fetch!(opts, :max_buffer_size)
    ]

    sender_opts = [
      name: sender_name(handler_id),
      storage: storage_name(handler_id),
      storage_module: Ets,
      loki_url: Keyword.fetch!(opts, :loki_url),
      batch_size: Keyword.fetch!(opts, :batch_size),
      batch_interval_ms: Keyword.fetch!(opts, :batch_interval_ms),
      backoff_base_ms: Keyword.fetch!(opts, :backoff_base_ms),
      backoff_max_ms: Keyword.fetch!(opts, :backoff_max_ms)
    ]

    children = [
      Supervisor.child_spec({Ets, storage_opts}, significant: true, restart: :transient),
      Supervisor.child_spec({Sender, sender_opts}, significant: true, restart: :transient)
    ]

    Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :all_significant)
  end

  @doc false
  def supervisor_name(handler_id) do
    :"Elixir.LokiLoggerHandler.EtsSupervisor.#{handler_id}"
  end

  @doc false
  def storage_name(handler_id) do
    :"Elixir.LokiLoggerHandler.Storage.#{handler_id}"
  end

  @doc false
  def sender_name(handler_id) do
    :"Elixir.LokiLoggerHandler.Sender.#{handler_id}"
  end
end
