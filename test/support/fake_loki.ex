defmodule LokiLoggerHandler.FakeLoki do
  @moduledoc """
  A fake Loki server for testing.

  Starts a Bandit HTTP server that accepts Loki push API requests and stores
  them for later assertion. Useful for testing the logger handler without
  a real Loki instance.

  ## Usage

      # Start the fake server
      {:ok, fake} = FakeLoki.start_link(port: 4100)

      # Configure handler to use it
      LokiLoggerHandler.attach(:test,
        loki_url: "http://localhost:4100",
        batch_interval_ms: 100
      )

      # Log something
      require Logger
      Logger.info("test message")

      # Wait for batch to be sent
      Process.sleep(200)

      # Get received entries
      entries = FakeLoki.get_entries(fake)

      # Assert on entries
      assert length(entries) == 1

      # Clean up
      FakeLoki.stop(fake)

  """

  use GenServer

  require Logger

  defstruct [:port, :server_pid, entries: []]

  # Client API

  @doc """
  Starts the fake Loki server.

  ## Options
    * `:port` - The port to listen on. Default: 4100
    * `:name` - Optional name to register the process under
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Returns all entries received by the fake server.

  Each entry is a map with `:stream` (labels) and `:values` (list of log entries).
  """
  @spec get_entries(GenServer.server()) :: [map()]
  def get_entries(server) do
    GenServer.call(server, :get_entries)
  end

  @doc """
  Returns all log values flattened from all streams.

  Each value is a tuple of `{timestamp, message, structured_metadata}`.
  Structured metadata may be nil if not present.
  """
  @spec get_log_values(GenServer.server()) :: [{String.t(), String.t(), map() | nil}]
  def get_log_values(server) do
    GenServer.call(server, :get_log_values)
  end

  @doc """
  Clears all stored entries.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  @doc """
  Returns the URL to use for the Loki handler configuration.
  """
  @spec url(GenServer.server()) :: String.t()
  def url(server) do
    GenServer.call(server, :url)
  end

  @doc """
  Stops the fake server.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 0)
    parent = self()

    # Start Bandit with our Router
    plug = {__MODULE__.Router, parent: parent}

    case Bandit.start_link(plug: plug, port: port, scheme: :http) do
      {:ok, server_pid} ->
        # Get the actual port (important when using port 0 for ephemeral ports)
        {:ok, {_ip, actual_port}} = ThousandIsland.listener_info(server_pid)

        state = %__MODULE__{
          port: actual_port,
          server_pid: server_pid,
          entries: []
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_entries, _from, state) do
    {:reply, Enum.reverse(state.entries), state}
  end

  def handle_call(:get_log_values, _from, state) do
    values =
      state.entries
      |> Enum.reverse()
      |> Enum.flat_map(fn %{"streams" => streams} ->
        Enum.flat_map(streams, fn %{"values" => values} ->
          Enum.map(values, &parse_value/1)
        end)
      end)

    {:reply, values, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: []}}
  end

  def handle_call(:url, _from, state) do
    {:reply, "http://localhost:#{state.port}", state}
  end

  def handle_call({:push, body}, _from, state) do
    {:reply, :ok, %{state | entries: [body | state.entries]}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.server_pid && Process.alive?(state.server_pid) do
      # Bandit doesn't have a stop function, use GenServer.stop
      GenServer.stop(state.server_pid, :normal)
    end

    :ok
  end

  defp parse_value([timestamp, message]) do
    {timestamp, message, nil}
  end

  defp parse_value([timestamp, message, metadata]) do
    {timestamp, message, metadata}
  end

  # Plug module for handling HTTP requests

  defmodule Router do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)

      case conn.request_path do
        "/loki/api/v1/push" ->
          handle_push(conn, parent)

        "/ready" ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, "ready")

        _ ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(404, "not found")
      end
    end

    defp handle_push(conn, parent) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode(body) do
        {:ok, decoded} ->
          GenServer.call(parent, {:push, decoded})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(204, "")

        {:error, _reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, ~s({"error": "invalid json"}))
      end
    end
  end
end
