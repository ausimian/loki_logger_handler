defmodule LokiLoggerHandler.Handler do
  # Erlang :logger handler implementation for Loki.
  #
  # This module implements the :logger handler callbacks. When a log event is received,
  # it is formatted and stored. A separate Sender process reads from storage
  # and sends batches to Loki.
  #
  # Handler Config:
  #   * :loki_url - Required. The Loki push API URL (e.g., "http://localhost:3100")
  #   * :storage - Storage strategy: :disk (CubDB) or :memory (ETS). Default: :disk
  #   * :labels - Map of label names to extraction rules. Default: %{level: :level}
  #   * :structured_metadata - List of metadata keys for Loki structured metadata. Default: []
  #   * :data_dir - Directory for CubDB storage (disk only). Default: "priv/loki_buffer/<handler_id>"
  #   * :batch_size - Max entries per batch. Default: 100
  #   * :batch_interval_ms - Max time between batches in ms. Default: 5000
  #   * :max_buffer_size - Max entries in buffer before dropping oldest. Default: 10_000
  #   * :backoff_base_ms - Base backoff time on failure. Default: 1000
  #   * :backoff_max_ms - Max backoff time. Default: 60_000

  @moduledoc false

  alias LokiLoggerHandler.{CubSupervisor, EtsSupervisor, Formatter}
  alias LokiLoggerHandler.Storage.{Cub, Ets}

  @behaviour :logger_handler

  @default_labels %{level: :level}
  @default_batch_size 100
  @default_batch_interval_ms 5_000
  @default_max_buffer_size 10_000
  @default_backoff_base_ms 1_000
  @default_backoff_max_ms 60_000

  # Logger handler callback for processing log events.
  # Formats the event and stores it for later sending.
  #
  # This callback runs inline in the process that called Logger and is wrapped
  # by Erlang's logger, which removes a handler whose log/2 raises. To guarantee
  # the handler survives any single bad event, formatting is wrapped in a rescue
  # that falls back to a best-effort entry and emits a telemetry event, rather
  # than letting the exception propagate and disable the handler.
  @impl :logger_handler
  def log(%{level: _level, msg: _msg, meta: _meta} = event, %{config: config}) do
    handler_id = config.handler_id
    storage_module = config.storage_module
    labels = Map.get(config, :labels, @default_labels)
    structured_metadata = Map.get(config, :structured_metadata, [])

    entry =
      try do
        Formatter.format(event, labels, structured_metadata)
      rescue
        exception ->
          emit_format_error(handler_id, exception, __STACKTRACE__)
          fallback_entry(event)
      catch
        kind, reason ->
          emit_format_error(handler_id, {kind, reason}, __STACKTRACE__)
          fallback_entry(event)
      end

    storage_module.store(handler_id, entry)

    :ok
  end

  # Called when the handler is being added to :logger.
  # Validates configuration and starts the appropriate supervisor (CubSupervisor or EtsSupervisor).
  @impl :logger_handler
  def adding_handler(%{id: id, config: config} = handler_config) do
    with :ok <- validate_config(config) do
      storage_strategy = Map.get(config, :storage, :disk)
      storage_module = storage_module(storage_strategy)
      data_dir = Map.get(config, :data_dir, default_data_dir(id))

      supervisor_opts = [
        handler_id: id,
        data_dir: data_dir,
        max_buffer_size: Map.get(config, :max_buffer_size, @default_max_buffer_size),
        loki_url: Map.fetch!(config, :loki_url),
        batch_size: Map.get(config, :batch_size, @default_batch_size),
        batch_interval_ms: Map.get(config, :batch_interval_ms, @default_batch_interval_ms),
        backoff_base_ms: Map.get(config, :backoff_base_ms, @default_backoff_base_ms),
        backoff_max_ms: Map.get(config, :backoff_max_ms, @default_backoff_max_ms),
        storage_module: storage_module
      ]

      case start_storage_supervisor(storage_strategy, supervisor_opts) do
        {:ok, pid} ->
          # Update config with derived values
          updated_config =
            config
            |> Map.put(:handler_id, id)
            |> Map.put(:storage_module, storage_module)
            |> Map.put(:supervisor_pid, pid)
            |> Map.put(:storage, storage_strategy)
            |> Map.put(:data_dir, data_dir)

          {:ok, %{handler_config | config: updated_config}}

        {:error, reason} ->
          {:error, {:supervisor_start_failed, reason}}
      end
    end
  end

  # Called when the handler is being removed from :logger.
  # Stops the supervisor (which stops Storage and Sender).
  @impl :logger_handler
  def removing_handler(%{config: config}) do
    case Map.get(config, :supervisor_pid) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(LokiLoggerHandler.DynamicSupervisor, pid)
    end

    :ok
  end

  # Called when the handler configuration is being changed.
  @impl :logger_handler
  def changing_config(:set, %{config: old_config}, %{config: new_config} = handler_config) do
    with :ok <- validate_config(new_config) do
      # Preserve internal config values
      updated_config =
        new_config
        |> Map.put(:handler_id, old_config.handler_id)
        |> Map.put(:storage_module, old_config.storage_module)
        |> Map.put(:supervisor_pid, old_config.supervisor_pid)
        |> Map.put(:storage, old_config.storage)
        |> Map.put(:data_dir, old_config.data_dir)

      {:ok, %{handler_config | config: updated_config}}
    end
  end

  def changing_config(:update, %{config: old_config}, %{config: new_config} = handler_config) do
    merged_config = Map.merge(old_config, new_config)

    with :ok <- validate_config(merged_config) do
      {:ok, %{handler_config | config: merged_config}}
    end
  end

  @doc false
  @impl :logger_handler
  def filter_config(%{config: config} = handler_config) do
    # Remove internal keys when reporting config
    filtered =
      config
      |> Map.drop([:handler_id, :storage_module, :supervisor_pid])

    %{handler_config | config: filtered}
  end

  # Private Functions

  # Best-effort entry used when Formatter.format/3 fails. Avoids any code path
  # that could raise so that a single malformed event can never take the handler
  # down. The raw message is inspected and only the level label is attached.
  defp fallback_entry(%{level: level, msg: msg}) do
    %{
      timestamp: System.system_time(:nanosecond),
      level: level,
      message: "[loki_logger_handler] failed to format log event: " <> inspect(msg),
      labels: %{"level" => to_string(level)},
      structured_metadata: %{}
    }
  end

  defp emit_format_error(handler_id, reason, stacktrace) do
    :telemetry.execute(
      [:loki_logger_handler, :format, :error],
      %{count: 1},
      %{handler_id: handler_id, reason: reason, stacktrace: stacktrace}
    )
  end

  defp validate_config(config) do
    cond do
      not Map.has_key?(config, :loki_url) ->
        {:error, {:missing_config, :loki_url}}

      not is_binary(Map.get(config, :loki_url)) ->
        {:error, {:invalid_config, :loki_url, "must be a string"}}

      true ->
        :ok
    end
  end

  defp default_data_dir(handler_id) do
    Path.join(["priv", "loki_buffer", to_string(handler_id)])
  end

  defp storage_module(:disk), do: Cub
  defp storage_module(:memory), do: Ets

  defp start_storage_supervisor(:disk, opts) do
    DynamicSupervisor.start_child(
      LokiLoggerHandler.DynamicSupervisor,
      {CubSupervisor, opts}
    )
  end

  defp start_storage_supervisor(:memory, opts) do
    DynamicSupervisor.start_child(
      LokiLoggerHandler.DynamicSupervisor,
      {EtsSupervisor, opts}
    )
  end
end
