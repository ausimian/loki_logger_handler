defmodule LokiLoggerHandler do
  @moduledoc """
  Elixir Logger handler for Grafana Loki.

  This library implements an Erlang `:logger` handler that buffers logs and sends
  them to Loki in batches. It supports:

  - Configurable label extraction for Loki stream labels
  - Structured metadata (Loki 2.9+)
  - Two storage strategies: disk (CubDB) or memory (ETS)
  - Dual threshold batching (time and size)
  - Exponential backoff on failures
  - Multiple handler instances for different Loki endpoints

  ## Quick Start

      # Attach a handler
      LokiLoggerHandler.attach(:my_handler,
        loki_url: "http://localhost:3100",
        labels: %{
          app: {:static, "myapp"},
          env: {:metadata, :env},
          level: :level
        },
        structured_metadata: [:request_id, :user_id]
      )

      # Now use Logger as usual
      require Logger
      Logger.info("Hello Loki!", request_id: "abc123")

      # Later, detach if needed
      LokiLoggerHandler.detach(:my_handler)

  ## Configuration Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:loki_url` | string | required | Loki push API base URL |
  | `:storage` | atom | `:disk` | Storage strategy: `:disk` (CubDB) or `:memory` (ETS) |
  | `:labels` | map | `%{level: :level}` | Label extraction config |
  | `:structured_metadata` | list | `[]` | Metadata keys for Loki structured metadata |
  | `:data_dir` | string | `"priv/loki_buffer/<id>"` | CubDB storage directory (disk only) |
  | `:batch_size` | integer | 100 | Max entries per batch |
  | `:batch_interval_ms` | integer | 5000 | Max time between batches |
  | `:max_buffer_size` | integer | 10000 | Max buffered entries before dropping |
  | `:backoff_base_ms` | integer | 1000 | Base backoff on failure |
  | `:backoff_max_ms` | integer | 60000 | Max backoff time |

  ## Label Configuration

  Labels are configured as a map where keys are the Loki label names and values
  specify how to extract the label value:

  - `:level` - Use the log level
  - `{:metadata, key}` - Extract from log metadata
  - `{:static, value}` - Use a static value

  Example:

      labels: %{
        app: {:static, "myapp"},
        environment: {:metadata, :env},
        level: :level,
        node: {:metadata, :node}
      }

  ## Structured Metadata (Loki 2.9+)

  Structured metadata allows attaching key-value pairs that aren't indexed as labels
  but can still be queried. Specify a list of metadata keys to extract:

      structured_metadata: [:request_id, :user_id, :trace_id, :span_id]

  """

  alias LokiLoggerHandler.Handler

  @type handler_id :: atom()
  @type option ::
          {:loki_url, String.t()}
          | {:storage, :disk | :memory}
          | {:labels, map()}
          | {:structured_metadata, [atom()]}
          | {:data_dir, String.t()}
          | {:batch_size, pos_integer()}
          | {:batch_interval_ms, pos_integer()}
          | {:max_buffer_size, pos_integer()}
          | {:backoff_base_ms, pos_integer()}
          | {:backoff_max_ms, pos_integer()}

  @doc """
  Attaches a new Loki logger handler.

  ## Parameters
    * `handler_id` - A unique atom identifier for this handler
    * `opts` - Configuration options (see module docs)

  ## Returns
    * `:ok` on success
    * `{:error, reason}` on failure

  ## Examples

      LokiLoggerHandler.attach(:default,
        loki_url: "http://localhost:3100",
        labels: %{app: {:static, "myapp"}, level: :level}
      )

  """
  @spec attach(handler_id(), [option()]) :: :ok | {:error, term()}
  def attach(handler_id, opts) when is_atom(handler_id) and is_list(opts) do
    config = Map.new(opts)

    case :logger.add_handler(handler_id, Handler, %{config: config}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Detaches a Loki logger handler.

  ## Parameters
    * `handler_id` - The handler identifier used when attaching

  ## Returns
    * `:ok` on success
    * `{:error, reason}` if the handler doesn't exist

  ## Examples

      LokiLoggerHandler.detach(:default)

  """
  @spec detach(handler_id()) :: :ok | {:error, term()}
  def detach(handler_id) when is_atom(handler_id) do
    case :logger.remove_handler(handler_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Forces an immediate flush of all pending logs for a handler.

  Useful before application shutdown to ensure all logs are sent.

  ## Parameters
    * `handler_id` - The handler identifier

  ## Returns
    * `:ok` on success
    * `{:error, reason}` on failure
  """
  @spec flush(handler_id()) :: :ok | {:error, term()}
  def flush(handler_id) when is_atom(handler_id) do
    sender = LokiLoggerHandler.Application.via(LokiLoggerHandler.Sender, handler_id)
    LokiLoggerHandler.Sender.flush(sender)
  end

  @doc """
  Updates the configuration of an existing handler.

  ## Parameters
    * `handler_id` - The handler identifier
    * `opts` - New configuration options to merge

  ## Returns
    * `:ok` on success
    * `{:error, reason}` on failure
  """
  @spec update_config(handler_id(), [option()]) :: :ok | {:error, term()}
  def update_config(handler_id, opts) when is_atom(handler_id) and is_list(opts) do
    config = Map.new(opts)
    :logger.update_handler_config(handler_id, :config, config)
  end

  @doc """
  Returns the current configuration for a handler.

  ## Parameters
    * `handler_id` - The handler identifier

  ## Returns
    * `{:ok, config}` with the handler configuration
    * `{:error, reason}` if the handler doesn't exist
  """
  @spec get_config(handler_id()) :: {:ok, map()} | {:error, term()}
  def get_config(handler_id) when is_atom(handler_id) do
    case :logger.get_handler_config(handler_id) do
      {:ok, %{config: config}} -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all attached Loki logger handlers.

  ## Returns
  A list of handler IDs that are using this handler module.
  """
  @spec list_handlers() :: [handler_id()]
  def list_handlers do
    :logger.get_handler_config()
    |> Enum.filter(fn %{module: module} -> module == Handler end)
    |> Enum.map(fn %{id: id} -> id end)
  end
end
