defmodule LokiLoggerHandler.Storage.Ets do
  # GenServer wrapping ETS for in-memory log storage.
  #
  # Each handler instance has its own Storage process with a separate ETS table.
  # Logs are stored with monotonic timestamp keys to ensure ordering.
  # Unlike CubDB, this storage is not persistent - logs are lost on restart.
  #
  # The ETS table is public so read operations (fetch_batch, count) can bypass
  # the GenServer for better performance. Write operations still go through
  # the GenServer to enforce max_buffer_size.

  @moduledoc false

  use GenServer

  defstruct [:name, :table, :max_buffer_size]

  # Client API

  # Starts a Storage process linked to the current process.
  #
  # Options:
  #   * :name - Required. The name to register the process under.
  #   * :max_buffer_size - Optional. Maximum entries before dropping oldest. Default: 10_000.
  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name, hibernate_after: 15_000)
  end

  # Stores a log entry with an auto-generated monotonic key.
  # Goes through GenServer to enforce max_buffer_size.
  @doc false
  @spec store(GenServer.server(), map()) :: :ok
  def store(server, entry) do
    GenServer.cast(server, {:store, entry})
  end

  # Fetches up to `limit` entries from the beginning of the log.
  # Accesses ETS directly for better performance.
  # Returns a list of {key, entry} tuples ordered by key.
  @doc false
  @spec fetch_batch(GenServer.server(), pos_integer()) :: [{tuple(), map()}]
  def fetch_batch(server, limit) do
    table = get_table(server)
    fetch_first_n(table, limit)
  end

  # Deletes all entries with keys less than or equal to max_key.
  # Accesses ETS directly for better performance.
  @doc false
  @spec delete_up_to(GenServer.server(), tuple()) :: :ok
  def delete_up_to(server, max_key) do
    table = get_table(server)
    delete_keys_up_to(table, max_key)
    :ok
  end

  # Returns the current count of entries in storage.
  # Accesses ETS directly for better performance.
  @doc false
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server) do
    table = get_table(server)
    :ets.info(table, :size)
  end

  # Stops the Storage process.
  @doc false
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  # Returns the ETS table reference for direct access.
  # Uses :persistent_term for O(1) lookup.
  defp get_table(server) when is_atom(server) do
    :persistent_term.get({__MODULE__, server})
  end

  defp get_table(server) when is_pid(server) do
    GenServer.call(server, :get_table)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, 10_000)

    # Create public ordered_set for direct client access
    table = :ets.new(name, [:ordered_set, :public, :named_table])

    # Store table reference in persistent_term for fast lookup
    :persistent_term.put({__MODULE__, name}, table)

    state = %__MODULE__{
      name: name,
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
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_table, _from, state) do
    {:reply, state.table, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up persistent_term entry
    :persistent_term.erase({__MODULE__, state.name})

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
