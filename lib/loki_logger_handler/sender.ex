defmodule LokiLoggerHandler.Sender do
  @moduledoc """
  GenServer that batches and sends logs to Loki.

  Reads log entries from Storage and sends them to Loki in batches.
  Uses dual threshold batching: sends when either time interval OR batch size is reached.
  Implements exponential backoff on failures.
  """

  use GenServer

  alias LokiLoggerHandler.{Storage, LokiClient}

  require Logger

  defstruct [
    :name,
    :storage,
    :loki_url,
    :batch_size,
    :batch_interval_ms,
    :backoff_base_ms,
    :backoff_max_ms,
    :timer_ref,
    consecutive_failures: 0
  ]

  # Client API

  @doc """
  Starts a Sender process linked to the current process.

  ## Options
    * `:name` - Required. The name to register the process under.
    * `:storage` - Required. The Storage process name or pid.
    * `:loki_url` - Required. The Loki base URL.
    * `:batch_size` - Optional. Max entries per batch. Default: 100.
    * `:batch_interval_ms` - Optional. Max time between sends in ms. Default: 5000.
    * `:backoff_base_ms` - Optional. Base backoff time on failure. Default: 1000.
    * `:backoff_max_ms` - Optional. Max backoff time. Default: 60000.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Forces an immediate flush of pending logs.

  Returns `:ok` on success or `{:error, reason}` if the send fails.
  """
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server) do
    GenServer.call(server, :flush, :infinity)
  end

  @doc """
  Returns the current state of the sender for debugging.
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      storage: Keyword.fetch!(opts, :storage),
      loki_url: Keyword.fetch!(opts, :loki_url),
      batch_size: Keyword.get(opts, :batch_size, 100),
      batch_interval_ms: Keyword.get(opts, :batch_interval_ms, 5_000),
      backoff_base_ms: Keyword.get(opts, :backoff_base_ms, 1_000),
      backoff_max_ms: Keyword.get(opts, :backoff_max_ms, 60_000),
      consecutive_failures: 0
    }

    # Schedule first batch check
    timer_ref = schedule_batch_check(state.batch_interval_ms)
    state = %{state | timer_ref: timer_ref}

    {:ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    case do_send_batch(state, :all) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_info(:batch_check, state) do
    # Cancel old timer if present
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Check if we should send
    state =
      case should_send?(state) do
        true ->
          case do_send_batch(state, state.batch_size) do
            {:ok, new_state} -> new_state
            {:error, _reason, new_state} -> new_state
          end

        false ->
          state
      end

    # Schedule next check based on backoff state
    interval = next_interval(state)
    timer_ref = schedule_batch_check(interval)

    {:noreply, %{state | timer_ref: timer_ref}}
  end

  # Private Functions

  defp schedule_batch_check(interval_ms) do
    Process.send_after(self(), :batch_check, interval_ms)
  end

  defp should_send?(state) do
    # Always try to send if there are entries (the timer handles throttling)
    case Storage.count(state.storage) do
      count when count > 0 -> true
      _ -> false
    end
  end

  defp do_send_batch(state, limit) do
    batch =
      case limit do
        :all -> Storage.fetch_batch(state.storage, 10_000)
        n -> Storage.fetch_batch(state.storage, n)
      end

    case batch do
      [] ->
        {:ok, state}

      entries ->
        # Extract just the values (entries are {key, value} tuples)
        log_entries = Enum.map(entries, fn {_key, entry} -> entry end)

        case LokiClient.push(state.loki_url, log_entries) do
          :ok ->
            # Delete sent entries
            {max_key, _} = List.last(entries)
            Storage.delete_up_to(state.storage, max_key)
            {:ok, %{state | consecutive_failures: 0}}

          {:error, reason} ->
            Logger.warning(
              "[LokiLoggerHandler] Failed to send to Loki: #{inspect(reason)}, " <>
                "consecutive failures: #{state.consecutive_failures + 1}"
            )

            {:error, reason, %{state | consecutive_failures: state.consecutive_failures + 1}}
        end
    end
  end

  defp next_interval(state) do
    if state.consecutive_failures > 0 do
      # Exponential backoff: base * 2^(failures - 1), capped at max
      backoff =
        state.backoff_base_ms *
          Integer.pow(2, min(state.consecutive_failures - 1, 10))

      min(backoff, state.backoff_max_ms)
    else
      state.batch_interval_ms
    end
  end
end
