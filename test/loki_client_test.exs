defmodule LokiLoggerHandler.LokiClientTest do
  use ExUnit.Case, async: false

  alias LokiLoggerHandler.LokiClient
  alias LokiLoggerHandler.FakeLoki

  describe "push/2" do
    test "returns :ok for empty list without making request" do
      # No server needed - should return immediately
      assert :ok = LokiClient.push("http://localhost:9999", [])
    end

    test "successfully pushes entries to Loki" do
      {:ok, fake} = FakeLoki.start_link(port: 4300)
      url = FakeLoki.url(fake)

      entries = [
        %{
          timestamp: 1_000_000_000,
          level: :info,
          message: "test message",
          labels: %{"level" => "info"},
          structured_metadata: %{}
        }
      ]

      assert :ok = LokiClient.push(url, entries)

      # Verify it was received
      received = FakeLoki.get_entries(fake)
      assert length(received) == 1

      FakeLoki.stop(fake)
    end

    test "returns error for HTTP error responses" do
      # Use a mock approach - start fake server that returns errors
      {:ok, fake} = start_error_server(port: 4301, status: 500, body: ~s({"error": "internal server error"}))

      result = LokiClient.push("http://localhost:4301", [sample_entry()])

      assert {:error, {:http_error, 500, _body}} = result

      stop_error_server(fake)
    end

    test "returns error for 400 Bad Request" do
      {:ok, fake} = start_error_server(port: 4302, status: 400, body: ~s({"error": "bad request"}))

      result = LokiClient.push("http://localhost:4302", [sample_entry()])

      assert {:error, {:http_error, 400, _body}} = result

      stop_error_server(fake)
    end

    test "returns error when connection fails" do
      # Try to connect to a port with nothing listening
      result = LokiClient.push("http://localhost:59999", [sample_entry()])

      assert {:error, {:request_failed, _exception}} = result
    end

    test "handles 204 No Content response" do
      {:ok, fake} = FakeLoki.start_link(port: 4303)
      url = FakeLoki.url(fake)

      # FakeLoki returns 204, which should be treated as success
      assert :ok = LokiClient.push(url, [sample_entry()])

      FakeLoki.stop(fake)
    end
  end

  describe "build_push_body/1" do
    test "builds correct structure for single entry" do
      entries = [
        %{
          timestamp: 1_000_000_000,
          level: :info,
          message: "test message",
          labels: %{"app" => "test"},
          structured_metadata: %{}
        }
      ]

      result = LokiClient.build_push_body(entries)

      assert %{"streams" => [stream]} = result
      assert stream["stream"] == %{"app" => "test"}
      assert [["1000000000", "test message"]] = stream["values"]
    end

    test "groups entries by labels into separate streams" do
      entries = [
        %{
          timestamp: 1_000_000_000,
          level: :info,
          message: "info message",
          labels: %{"level" => "info"},
          structured_metadata: %{}
        },
        %{
          timestamp: 2_000_000_000,
          level: :error,
          message: "error message",
          labels: %{"level" => "error"},
          structured_metadata: %{}
        },
        %{
          timestamp: 3_000_000_000,
          level: :info,
          message: "another info",
          labels: %{"level" => "info"},
          structured_metadata: %{}
        }
      ]

      result = LokiClient.build_push_body(entries)

      assert %{"streams" => streams} = result
      assert length(streams) == 2

      info_stream = Enum.find(streams, &(&1["stream"]["level"] == "info"))
      error_stream = Enum.find(streams, &(&1["stream"]["level"] == "error"))

      assert length(info_stream["values"]) == 2
      assert length(error_stream["values"]) == 1
    end

    test "sorts entries by timestamp within each stream" do
      entries = [
        %{
          timestamp: 3_000_000_000,
          level: :info,
          message: "third",
          labels: %{"app" => "test"},
          structured_metadata: %{}
        },
        %{
          timestamp: 1_000_000_000,
          level: :info,
          message: "first",
          labels: %{"app" => "test"},
          structured_metadata: %{}
        },
        %{
          timestamp: 2_000_000_000,
          level: :info,
          message: "second",
          labels: %{"app" => "test"},
          structured_metadata: %{}
        }
      ]

      result = LokiClient.build_push_body(entries)

      [stream] = result["streams"]
      messages = Enum.map(stream["values"], fn [_ts, msg | _] -> msg end)

      assert messages == ["first", "second", "third"]
    end

    test "includes structured metadata when present" do
      entries = [
        %{
          timestamp: 1_000_000_000,
          level: :info,
          message: "with metadata",
          labels: %{"app" => "test"},
          structured_metadata: %{"request_id" => "abc123", "user_id" => "user456"}
        }
      ]

      result = LokiClient.build_push_body(entries)

      [stream] = result["streams"]
      [[timestamp, message, metadata]] = stream["values"]

      assert timestamp == "1000000000"
      assert message == "with metadata"
      assert metadata == %{"request_id" => "abc123", "user_id" => "user456"}
    end

    test "omits structured metadata when empty" do
      entries = [
        %{
          timestamp: 1_000_000_000,
          level: :info,
          message: "no metadata",
          labels: %{"app" => "test"},
          structured_metadata: %{}
        }
      ]

      result = LokiClient.build_push_body(entries)

      [stream] = result["streams"]
      # Should be [timestamp, message] without third element
      assert [[timestamp, message]] = stream["values"]
      assert timestamp == "1000000000"
      assert message == "no metadata"
    end

    test "handles multiple label combinations" do
      entries = [
        %{
          timestamp: 1_000_000_000,
          level: :info,
          message: "app1 info",
          labels: %{"app" => "app1", "level" => "info"},
          structured_metadata: %{}
        },
        %{
          timestamp: 2_000_000_000,
          level: :info,
          message: "app2 info",
          labels: %{"app" => "app2", "level" => "info"},
          structured_metadata: %{}
        },
        %{
          timestamp: 3_000_000_000,
          level: :error,
          message: "app1 error",
          labels: %{"app" => "app1", "level" => "error"},
          structured_metadata: %{}
        }
      ]

      result = LokiClient.build_push_body(entries)

      assert length(result["streams"]) == 3
    end
  end

  # Helper functions

  defp sample_entry do
    %{
      timestamp: System.system_time(:nanosecond),
      level: :info,
      message: "test message",
      labels: %{"level" => "info"},
      structured_metadata: %{}
    }
  end

  # Simple error server for testing HTTP error responses
  defp start_error_server(opts) do
    port = Keyword.fetch!(opts, :port)
    status = Keyword.fetch!(opts, :status)
    body = Keyword.fetch!(opts, :body)

    plug = {__MODULE__.ErrorPlug, status: status, body: body}

    case Bandit.start_link(plug: plug, port: port, scheme: :http) do
      {:ok, pid} -> {:ok, pid}
      error -> error
    end
  end

  defp stop_error_server(pid) do
    GenServer.stop(pid, :normal)
  end

  defmodule ErrorPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      status = Keyword.fetch!(opts, :status)
      body = Keyword.fetch!(opts, :body)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end
  end
end
