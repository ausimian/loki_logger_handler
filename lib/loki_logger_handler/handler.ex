defmodule LokiLoggerHandler.Handler do
  # Erlang :logger handler implementation for Loki.
  #
  # This module implements the :logger handler callbacks. When a log event is received,
  # it is formatted and stored in CubDB. A separate Sender process reads from CubDB
  # and sends batches to Loki.
  #
  # Handler Config:
  #   * :loki_url - Required. The Loki push API URL (e.g., "http://localhost:3100")
  #   * :labels - Map of label names to extraction rules. Default: %{level: :level}
  #   * :structured_metadata - List of metadata keys for Loki structured metadata. Default: []
  #   * :data_dir - Directory for CubDB storage. Default: "priv/loki_buffer/<handler_id>"
  #   * :batch_size - Max entries per batch. Default: 100
  #   * :batch_interval_ms - Max time between batches in ms. Default: 5000
  #   * :max_buffer_size - Max entries in buffer before dropping oldest. Default: 10_000
  #   * :backoff_base_ms - Base backoff time on failure. Default: 1000
  #   * :backoff_max_ms - Max backoff time. Default: 60_000

  @moduledoc false

  alias LokiLoggerHandler.{Formatter, Storage, PairSupervisor}

  @behaviour :logger_handler

  @default_labels %{level: :level}
  @default_batch_size 100
  @default_batch_interval_ms 5_000
  @default_max_buffer_size 10_000
  @default_backoff_base_ms 1_000
  @default_backoff_max_ms 60_000

  # Logger handler callback for processing log events.
  # Formats the event and stores it in CubDB for later sending.
  @impl :logger_handler
  def log(%{level: _level, msg: _msg, meta: _meta} = event, %{config: config}) do
    storage_name = config.storage_name
    labels = Map.get(config, :labels, @default_labels)
    structured_metadata = Map.get(config, :structured_metadata, [])

    entry = Formatter.format(event, labels, structured_metadata)
    Storage.store(storage_name, entry)

    :ok
  end

  # Called when the handler is being added to :logger.
  # Validates configuration and starts the PairSupervisor (which starts Storage and Sender).
  @impl :logger_handler
  def adding_handler(%{id: id, config: config} = handler_config) do
    with :ok <- validate_config(config) do
      # Build derived values
      data_dir = Map.get(config, :data_dir, default_data_dir(id))

      pair_supervisor_opts = [
        handler_id: id,
        data_dir: data_dir,
        max_buffer_size: Map.get(config, :max_buffer_size, @default_max_buffer_size),
        loki_url: Map.fetch!(config, :loki_url),
        batch_size: Map.get(config, :batch_size, @default_batch_size),
        batch_interval_ms: Map.get(config, :batch_interval_ms, @default_batch_interval_ms),
        backoff_base_ms: Map.get(config, :backoff_base_ms, @default_backoff_base_ms),
        backoff_max_ms: Map.get(config, :backoff_max_ms, @default_backoff_max_ms)
      ]

      case start_pair_supervisor(pair_supervisor_opts) do
        {:ok, _pid} ->
          # Update config with derived values
          updated_config =
            config
            |> Map.put(:storage_name, PairSupervisor.storage_name(id))
            |> Map.put(:sender_name, PairSupervisor.sender_name(id))
            |> Map.put(:pair_supervisor_name, PairSupervisor.supervisor_name(id))
            |> Map.put(:data_dir, data_dir)

          {:ok, %{handler_config | config: updated_config}}

        {:error, reason} ->
          {:error, {:pair_supervisor_start_failed, reason}}
      end
    end
  end

  # Called when the handler is being removed from :logger.
  # Stops the PairSupervisor (which stops Storage and Sender).
  @impl :logger_handler
  def removing_handler(%{id: id, config: config}) do
    pair_supervisor_name = Map.get(config, :pair_supervisor_name, PairSupervisor.supervisor_name(id))
    stop_pair_supervisor(pair_supervisor_name)
    :ok
  end

  # Called when the handler configuration is being changed.
  @impl :logger_handler
  def changing_config(:set, %{config: old_config}, %{config: new_config} = handler_config) do
    with :ok <- validate_config(new_config) do
      # Preserve internal config values
      updated_config =
        new_config
        |> Map.put(:storage_name, old_config.storage_name)
        |> Map.put(:sender_name, old_config.sender_name)
        |> Map.put(:pair_supervisor_name, old_config.pair_supervisor_name)
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
      |> Map.drop([:storage_name, :sender_name, :pair_supervisor_name])

    %{handler_config | config: filtered}
  end

  # Private Functions

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

  defp start_pair_supervisor(opts) do
    DynamicSupervisor.start_child(
      LokiLoggerHandler.Application,
      {PairSupervisor, opts}
    )
  end

  defp stop_pair_supervisor(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(LokiLoggerHandler.Application, pid)
    end
  end
end
