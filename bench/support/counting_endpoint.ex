defmodule LokiLoggerHandler.Bench.CountingEndpoint do
  @moduledoc """
  A minimal Loki endpoint that counts received messages.

  Unlike FakeLoki which stores all entries, this endpoint only maintains
  a counter for better benchmark performance (O(1) memory).
  """

  use GenServer

  defstruct [:port, :server_pid, count: 0]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def get_count(server) do
    GenServer.call(server, :get_count)
  end

  def reset(server) do
    GenServer.call(server, :reset)
  end

  def url(server) do
    GenServer.call(server, :url)
  end

  def stop(server) do
    GenServer.stop(server)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 4100)
    parent = self()

    plug = {__MODULE__.Router, parent: parent}

    case Bandit.start_link(plug: plug, port: port, scheme: :http, startup_log: false) do
      {:ok, server_pid} ->
        {:ok, %__MODULE__{port: port, server_pid: server_pid, count: 0}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_count, _from, state) do
    {:reply, state.count, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | count: 0}}
  end

  def handle_call(:url, _from, state) do
    {:reply, "http://localhost:#{state.port}", state}
  end

  def handle_call({:add_count, n}, _from, state) do
    {:reply, :ok, %{state | count: state.count + n}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.server_pid && Process.alive?(state.server_pid) do
      GenServer.stop(state.server_pid, :normal)
    end

    :ok
  end

  # Router module

  defmodule Router do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)

      case conn.request_path do
        "/loki/api/v1/push" ->
          handle_push(conn, parent)

        _ ->
          send_resp(conn, 404, "not found")
      end
    end

    defp handle_push(conn, parent) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode(body) do
        {:ok, %{"streams" => streams}} ->
          # Count total messages across all streams
          count =
            Enum.reduce(streams, 0, fn %{"values" => values}, acc ->
              acc + length(values)
            end)

          GenServer.call(parent, {:add_count, count})
          send_resp(conn, 204, "")

        _ ->
          send_resp(conn, 400, "invalid json")
      end
    end
  end
end
