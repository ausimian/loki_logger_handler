defmodule LokiLoggerHandler.Storage.Ets do
  # GenServer wrapping ETS for in-memory log storage.
  #
  # Each handler instance has its own Storage process with a separate ETS table.
  # Logs are stored with monotonic timestamp keys to ensure ordering.
  # Unlike CubDB, this storage is not persistent - logs are lost on restart.

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

  # Server Callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, 10_000)

    # Create ordered_set for efficient range queries
    # Public so we own the table and it dies with the process
    table = :ets.new(name, [:ordered_set, :protected])

    state = %__MODULE__{
      name: name,
      table: table,
      max_buffer_size: max_buffer_size
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:store, entry}, _from, state) do
    key = generate_key()

    # Enforce max buffer size by dropping oldest entries
    state = maybe_drop_oldest(state)

    :ets.insert(state.table, {key, entry})
    {:reply, {:ok, key}, state}
  end

  def handle_call({:fetch_batch, limit}, _from, state) do
    entries = fetch_first_n(state.table, limit)
    {:reply, entries, state}
  end

  def handle_call({:delete_up_to, max_key}, _from, state) do
    delete_keys_up_to(state.table, max_key)
    {:reply, :ok, state}
  end

  def handle_call(:count, _from, state) do
    count = :ets.info(state.table, :size)
    {:reply, count, state}
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

    state
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
    [{^key, entry}] = :ets.lookup(table, key)
    next_key = :ets.next(table, key)
    fetch_first_n(table, next_key, remaining - 1, [{key, entry} | acc])
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
