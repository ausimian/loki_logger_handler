defmodule LokiLoggerHandler.CubSupervisor do
  # Supervisor for a handler instance's CubDB Storage and Sender processes.
  #
  # Each handler instance using disk storage gets its own CubSupervisor which
  # supervises both the Storage.Cub (CubDB wrapper) and Sender processes together.
  #
  # Uses auto_shutdown: :all_significant so that when both children exit,
  # the supervisor itself exits cleanly.

  @moduledoc false

  use Supervisor

  alias LokiLoggerHandler.Storage.Cub
  alias LokiLoggerHandler.Sender

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    handler_id = Keyword.fetch!(opts, :handler_id)

    storage_opts = [
      handler_id: handler_id,
      data_dir: Keyword.fetch!(opts, :data_dir),
      max_buffer_size: Keyword.fetch!(opts, :max_buffer_size)
    ]

    sender_opts = [
      handler_id: handler_id,
      storage_module: Cub,
      loki_url: Keyword.fetch!(opts, :loki_url),
      batch_size: Keyword.fetch!(opts, :batch_size),
      batch_interval_ms: Keyword.fetch!(opts, :batch_interval_ms),
      backoff_base_ms: Keyword.fetch!(opts, :backoff_base_ms),
      backoff_max_ms: Keyword.fetch!(opts, :backoff_max_ms)
    ]

    children = [
      Supervisor.child_spec({Cub, storage_opts}, significant: true, restart: :transient),
      Supervisor.child_spec({Sender, sender_opts}, significant: true, restart: :transient)
    ]

    Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :all_significant)
  end
end
