defmodule LokiLoggerHandler.Storage.Cub do
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

  defstruct [:db, :data_dir, :max_buffer_size]

  # Client API

  # Starts a Storage process linked to the current process.
  #
  # Options:
  #   * :handler_id - Required. Used to register in the Registry.
  #   * :data_dir - Required. The directory path for CubDB storage.
  #   * :max_buffer_size - Optional. Maximum entries before dropping oldest. Default: 10_000.
  @doc false
  def start_link(opts) do
    handler_id = Keyword.fetch!(opts, :handler_id)
    name = LokiLoggerHandler.Application.via(__MODULE__, handler_id)
    GenServer.start_link(__MODULE__, opts, name: name, hibernate_after: 15_000)
  end

  # Stores a log entry with an auto-generated monotonic key.
  # This is a cast (fire-and-forget) for better performance.
  @doc false
  @spec store(atom(), entry()) :: :ok
  def store(handler_id, entry) do
    GenServer.cast(via(handler_id), {:store, entry})
  end

  # Fetches up to `limit` entries from the beginning of the log.
  # Returns a list of {key, entry} tuples ordered by key.
  @doc false
  @spec fetch_batch(atom(), pos_integer()) :: [{key(), entry()}]
  def fetch_batch(handler_id, limit) do
    GenServer.call(via(handler_id), {:fetch_batch, limit})
  end

  # Deletes all entries with keys less than or equal to max_key.
  # Used to remove entries after successful send to Loki.
  @doc false
  @spec delete_up_to(atom(), key()) :: :ok
  def delete_up_to(handler_id, max_key) do
    GenServer.call(via(handler_id), {:delete_up_to, max_key})
  end

  # Returns the current count of entries in storage.
  @doc false
  @spec count(atom()) :: non_neg_integer()
  def count(handler_id) do
    GenServer.call(via(handler_id), :count)
  end

  # Stops the Storage process.
  @doc false
  @spec stop(atom()) :: :ok
  def stop(handler_id) do
    GenServer.stop(via(handler_id))
  end

  defp via(handler_id) do
    LokiLoggerHandler.Application.via(__MODULE__, handler_id)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, 10_000)

    # Ensure directory exists
    File.mkdir_p!(data_dir)

    case CubDB.start_link(data_dir: data_dir) do
      {:ok, db} ->
        state = %__MODULE__{
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
  def handle_cast({:store, entry}, state) do
    key = generate_key()

    # Enforce max buffer size by dropping oldest entries
    state = maybe_drop_oldest(state)

    :ok = CubDB.put(state.db, key, entry)
    {:noreply, state}
  end

  @impl true
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
