defmodule LokiLoggerHandler.Storage do
  # Dispatch module for storage operations.
  #
  # Provides a unified API for different storage backends (CubDB for disk, ETS for memory).
  # The actual storage GenServer implements the same handle_call interface.

  @moduledoc false

  @type key :: {integer(), integer()}
  @type entry :: %{
          timestamp: integer(),
          level: atom(),
          message: binary(),
          labels: map(),
          structured_metadata: map()
        }

  # Stores a log entry with an auto-generated monotonic key.
  # Returns {:ok, key} on success.
  @doc false
  @spec store(GenServer.server(), entry()) :: {:ok, key()}
  def store(server, entry) do
    GenServer.call(server, {:store, entry})
  end

  # Fetches up to `limit` entries from the beginning of the log.
  # Returns a list of {key, entry} tuples ordered by key.
  @doc false
  @spec fetch_batch(GenServer.server(), pos_integer()) :: [{key(), entry()}]
  def fetch_batch(server, limit) do
    GenServer.call(server, {:fetch_batch, limit})
  end

  # Deletes all entries with keys less than or equal to max_key.
  # Used to remove entries after successful send to Loki.
  @doc false
  @spec delete_up_to(GenServer.server(), key()) :: :ok
  def delete_up_to(server, max_key) do
    GenServer.call(server, {:delete_up_to, max_key})
  end

  # Returns the current count of entries in storage.
  @doc false
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server) do
    GenServer.call(server, :count)
  end

  # Stops the Storage process.
  @doc false
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end
end
