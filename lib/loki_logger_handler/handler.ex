defmodule LokiLoggerHandler.Handler do
  @moduledoc """
  Erlang :logger handler implementation for Loki.

  This module implements the :logger handler callbacks. When a log event is received,
  it is formatted and stored in CubDB. A separate Sender process reads from CubDB
  and sends batches to Loki.

  ## Handler Config

  The handler config map supports the following keys:

    * `:loki_url` - Required. The Loki push API URL (e.g., "http://localhost:3100")
    * `:labels` - Map of label names to extraction rules. Default: `%{level: :level}`
    * `:structured_metadata` - List of metadata keys for Loki structured metadata. Default: `[]`
    * `:data_dir` - Directory for CubDB storage. Default: `"priv/loki_buffer/<handler_id>"`
    * `:batch_size` - Max entries per batch. Default: 100
    * `:batch_interval_ms` - Max time between batches in ms. Default: 5000
    * `:max_buffer_size` - Max entries in buffer before dropping oldest. Default: 10_000
    * `:backoff_base_ms` - Base backoff time on failure. Default: 1000
    * `:backoff_max_ms` - Max backoff time. Default: 60_000

  """

  alias LokiLoggerHandler.{Formatter, Storage, Sender}

  @behaviour :logger_handler

  @default_labels %{level: :level}
  @default_batch_size 100
  @default_batch_interval_ms 5_000
  @default_max_buffer_size 10_000
  @default_backoff_base_ms 1_000
  @default_backoff_max_ms 60_000

  @doc """
  Logger handler callback for processing log events.

  Formats the event and stores it in CubDB for later sending.
  """
  @impl :logger_handler
  def log(%{level: _level, msg: _msg, meta: _meta} = event, %{config: config}) do
    storage_name = config.storage_name
    labels = Map.get(config, :labels, @default_labels)
    structured_metadata = Map.get(config, :structured_metadata, [])

    entry = Formatter.format(event, labels, structured_metadata)
    Storage.store(storage_name, entry)

    :ok
  end

  @doc """
  Called when the handler is being added to :logger.

  Validates configuration and starts the Storage and Sender processes.
  """
  @impl :logger_handler
  def adding_handler(%{id: id, config: config} = handler_config) do
    with :ok <- validate_config(config) do
      # Build derived names and paths
      storage_name = storage_name(id)
      sender_name = sender_name(id)
      data_dir = Map.get(config, :data_dir, default_data_dir(id))

      # Start Storage process
      storage_opts = [
        name: storage_name,
        data_dir: data_dir,
        max_buffer_size: Map.get(config, :max_buffer_size, @default_max_buffer_size)
      ]

      case start_storage(storage_opts) do
        {:ok, _storage_pid} ->
          # Start Sender process
          sender_opts = [
            name: sender_name,
            storage: storage_name,
            loki_url: Map.fetch!(config, :loki_url),
            batch_size: Map.get(config, :batch_size, @default_batch_size),
            batch_interval_ms: Map.get(config, :batch_interval_ms, @default_batch_interval_ms),
            backoff_base_ms: Map.get(config, :backoff_base_ms, @default_backoff_base_ms),
            backoff_max_ms: Map.get(config, :backoff_max_ms, @default_backoff_max_ms)
          ]

          case start_sender(sender_opts) do
            {:ok, _sender_pid} ->
              # Update config with derived values
              updated_config =
                config
                |> Map.put(:storage_name, storage_name)
                |> Map.put(:sender_name, sender_name)
                |> Map.put(:data_dir, data_dir)

              {:ok, %{handler_config | config: updated_config}}

            {:error, reason} ->
              # Clean up storage on failure
              stop_storage(storage_name)
              {:error, {:sender_start_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:storage_start_failed, reason}}
      end
    end
  end

  @doc """
  Called when the handler is being removed from :logger.

  Stops the Storage and Sender processes.
  """
  @impl :logger_handler
  def removing_handler(%{id: id, config: config}) do
    sender_name = Map.get(config, :sender_name, sender_name(id))
    storage_name = Map.get(config, :storage_name, storage_name(id))

    stop_sender(sender_name)
    stop_storage(storage_name)

    :ok
  end

  @doc """
  Called when the handler configuration is being changed.
  """
  @impl :logger_handler
  def changing_config(:set, %{config: old_config}, %{config: new_config} = handler_config) do
    with :ok <- validate_config(new_config) do
      # Preserve internal config values
      updated_config =
        new_config
        |> Map.put(:storage_name, old_config.storage_name)
        |> Map.put(:sender_name, old_config.sender_name)
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
      |> Map.drop([:storage_name, :sender_name])

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

  defp storage_name(handler_id) do
    :"Elixir.LokiLoggerHandler.Storage.#{handler_id}"
  end

  defp sender_name(handler_id) do
    :"Elixir.LokiLoggerHandler.Sender.#{handler_id}"
  end

  defp default_data_dir(handler_id) do
    Path.join(["priv", "loki_buffer", to_string(handler_id)])
  end

  defp start_storage(opts) do
    # Start under the DynamicSupervisor
    DynamicSupervisor.start_child(
      LokiLoggerHandler.InstanceSupervisor,
      {Storage, opts}
    )
  end

  defp stop_storage(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(LokiLoggerHandler.InstanceSupervisor, pid)
    end
  end

  defp start_sender(opts) do
    DynamicSupervisor.start_child(
      LokiLoggerHandler.InstanceSupervisor,
      {Sender, opts}
    )
  end

  defp stop_sender(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(LokiLoggerHandler.InstanceSupervisor, pid)
    end
  end
end
