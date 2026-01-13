defmodule LokiLoggerHandler.Storage do
  # GenServer wrapping CubDB for persistent log storage.
  #
  # Each handler instance has its own Storage process with a separate CubDB database.
  # Logs are stored with monotonic timestamp keys to ensure ordering.

  @moduledoc false

  use GenServer

  @type key :: {integer(), integer()}
  @type entry :: %{
          timestamp: integer(),
          level: atom(),
          message: binary(),
          labels: map(),
          structured_metadata: map()
        }

  defstruct [:name, :db, :data_dir, :max_buffer_size]

  # Client API

  # Starts a Storage process linked to the current process.
  #
  # Options:
  #   * :name - Required. The name to register the process under.
  #   * :data_dir - Required. The directory path for CubDB storage.
  #   * :max_buffer_size - Optional. Maximum entries before dropping oldest. Default: 10_000.
  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name, hibernate_after: 15_000)
  end

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

  # Stops the Storage process and closes the CubDB database.
  @doc false
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    data_dir = Keyword.fetch!(opts, :data_dir)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, 10_000)

    # Ensure directory exists
    File.mkdir_p!(data_dir)

    case CubDB.start_link(data_dir: data_dir) do
      {:ok, db} ->
        state = %__MODULE__{
          name: name,
          db: db,
          data_dir: data_dir,
          max_buffer_size: max_buffer_size
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:store, entry}, _from, state) do
    key = generate_key()

    # Enforce max buffer size by dropping oldest entries
    state = maybe_drop_oldest(state)

    :ok = CubDB.put(state.db, key, entry)
    {:reply, {:ok, key}, state}
  end

  def handle_call({:fetch_batch, limit}, _from, state) do
    entries =
      state.db
      |> CubDB.select()
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  def handle_call({:delete_up_to, max_key}, _from, state) do
    keys_to_delete =
      state.db
      |> CubDB.select(max_key: max_key, max_key_inclusive: true)
      |> Enum.map(fn {key, _value} -> key end)

    CubDB.delete_multi(state.db, keys_to_delete)

    {:reply, :ok, state}
  end

  def handle_call(:count, _from, state) do
    count = CubDB.size(state.db)
    {:reply, count, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.db do
      CubDB.stop(state.db)
    end

    :ok
  end

  # Private Functions

  defp generate_key do
    {System.monotonic_time(:nanosecond), System.unique_integer([:monotonic, :positive])}
  end

  defp maybe_drop_oldest(state) do
    current_count = CubDB.size(state.db)

    if current_count >= state.max_buffer_size do
      # Drop oldest 10% to avoid dropping on every insert
      drop_count = max(div(state.max_buffer_size, 10), 1)

      keys_to_drop =
        state.db
        |> CubDB.select()
        |> Enum.take(drop_count)
        |> Enum.map(fn {key, _value} -> key end)

      CubDB.delete_multi(state.db, keys_to_drop)
    end

    state
  end
end
