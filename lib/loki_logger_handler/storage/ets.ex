defmodule LokiLoggerHandler.Storage.Ets do
  # GenServer wrapping ETS for in-memory log storage.
  #
  # Each handler instance has its own Storage process with a separate ETS table.
  # Logs are stored with monotonic timestamp keys to ensure ordering.
  # Unlike CubDB, this storage is not persistent - logs are lost on restart.
  #
  # The ETS table is public and named after the handler_id, so read operations
  # (fetch_batch, count, delete_up_to) can access it directly for better performance.
  # Write operations (store) go through the GenServer to enforce max_buffer_size.

  @moduledoc false

  use GenServer

  defstruct [:handler_id, :table, :max_buffer_size]

  # Client API

  # Starts a Storage process linked to the current process.
  #
  # Options:
  #   * :handler_id - Required. Used as the ETS table name and for Registry.
  #   * :max_buffer_size - Optional. Maximum entries before dropping oldest. Default: 10_000.
  @doc false
  def start_link(opts) do
    handler_id = Keyword.fetch!(opts, :handler_id)
    name = LokiLoggerHandler.Application.via(__MODULE__, handler_id)
    GenServer.start_link(__MODULE__, opts, name: name, hibernate_after: 15_000)
  end

  # Stores a log entry with an auto-generated monotonic key.
  # Goes through GenServer to enforce max_buffer_size.
  # The handler_id is used directly as the ETS table name.
  @doc false
  @spec store(atom(), map()) :: :ok
  def store(handler_id, entry) do
    GenServer.cast(
      {:via, Registry, {LokiLoggerHandler.Registry, {__MODULE__, handler_id}}},
      {:store, entry}
    )
  end

  # Fetches up to `limit` entries from the beginning of the log.
  # Accesses ETS directly using handler_id as the table name.
  # Returns a list of {key, entry} tuples ordered by key.
  @doc false
  @spec fetch_batch(atom(), pos_integer()) :: [{tuple(), map()}]
  def fetch_batch(handler_id, limit) do
    fetch_first_n(handler_id, limit)
  end

  # Deletes all entries with keys less than or equal to max_key.
  # Accesses ETS directly using handler_id as the table name.
  @doc false
  @spec delete_up_to(atom(), tuple()) :: :ok
  def delete_up_to(handler_id, max_key) do
    delete_keys_up_to(handler_id, max_key)

    :telemetry.execute(
      [:loki_logger_handler, :buffer, :remove],
      %{count: :ets.info(handler_id, :size)},
      %{handler_id: handler_id, storage: :ets}
    )

    :ok
  end

  # Returns the current count of entries in storage.
  # Accesses ETS directly using handler_id as the table name.
  @doc false
  @spec count(atom()) :: non_neg_integer()
  def count(handler_id) do
    :ets.info(handler_id, :size)
  end

  # Stops the Storage process.
  @doc false
  @spec stop(atom()) :: :ok
  def stop(handler_id) do
    GenServer.stop({:via, Registry, {LokiLoggerHandler.Registry, {__MODULE__, handler_id}}})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    handler_id = Keyword.fetch!(opts, :handler_id)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, 10_000)

    # Create public ordered_set with handler_id as the table name
    table = :ets.new(handler_id, [:ordered_set, :public, :named_table])

    state = %__MODULE__{
      handler_id: handler_id,
      table: table,
      max_buffer_size: max_buffer_size
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:store, entry}, state) do
    key = generate_key()

    # Enforce max buffer size by dropping oldest entries
    maybe_drop_oldest(state)

    :ets.insert(state.table, {key, entry})

    :telemetry.execute(
      [:loki_logger_handler, :buffer, :insert],
      %{count: :ets.info(state.table, :size)},
      %{handler_id: state.handler_id, storage: :ets}
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.table do
      :ets.delete(state.table)
    end

    :ok
  end

  # Private Functions

  defp generate_key do
    {System.monotonic_time(:nanosecond), System.unique_integer([:monotonic, :positive])}
  end

  defp maybe_drop_oldest(state) do
    current_count = :ets.info(state.table, :size)

    if current_count >= state.max_buffer_size do
      # Drop oldest 10% to avoid dropping on every insert
      drop_count = max(div(state.max_buffer_size, 10), 1)
      drop_first_n(state.table, drop_count)
    end
  end

  defp fetch_first_n(table, limit) do
    fetch_first_n(table, :ets.first(table), limit, [])
  end

  defp fetch_first_n(_table, :"$end_of_table", _remaining, acc) do
    Enum.reverse(acc)
  end

  defp fetch_first_n(_table, _key, 0, acc) do
    Enum.reverse(acc)
  end

  defp fetch_first_n(table, key, remaining, acc) do
    case :ets.lookup(table, key) do
      [{^key, entry}] ->
        next_key = :ets.next(table, key)
        fetch_first_n(table, next_key, remaining - 1, [{key, entry} | acc])

      [] ->
        # Key was deleted between first/next and lookup, continue
        next_key = :ets.next(table, key)
        fetch_first_n(table, next_key, remaining, acc)
    end
  end

  defp drop_first_n(_table, 0), do: :ok

  defp drop_first_n(table, count) do
    case :ets.first(table) do
      :"$end_of_table" ->
        :ok

      key ->
        :ets.delete(table, key)
        drop_first_n(table, count - 1)
    end
  end

  defp delete_keys_up_to(table, max_key) do
    delete_keys_up_to(table, :ets.first(table), max_key)
  end

  defp delete_keys_up_to(_table, :"$end_of_table", _max_key), do: :ok

  defp delete_keys_up_to(table, key, max_key) when key <= max_key do
    next_key = :ets.next(table, key)
    :ets.delete(table, key)
    delete_keys_up_to(table, next_key, max_key)
  end

  defp delete_keys_up_to(_table, _key, _max_key), do: :ok
end
