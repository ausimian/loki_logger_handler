defmodule LokiLoggerHandlerTest do
  use ExUnit.Case, async: false

  alias LokiLoggerHandler.FakeLoki

  @test_dir "test/tmp/handler_test"

  require Logger

  setup do
    # Clean up test directory
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    # Start fake Loki server
    {:ok, fake} = FakeLoki.start_link(port: 4200)
    url = FakeLoki.url(fake)

    on_exit(fn ->
      # Clean up any handlers that might be attached
      for handler_id <- LokiLoggerHandler.list_handlers() do
        LokiLoggerHandler.detach(handler_id)
      end

      catch_exit(FakeLoki.stop(fake))
      File.rm_rf!(@test_dir)
    end)

    {:ok, fake: fake, url: url}
  end

  describe "attach/2" do
    test "attaches a handler successfully", %{url: url} do
      assert :ok =
               LokiLoggerHandler.attach(:test_handler,
                 loki_url: url,
                 data_dir: Path.join(@test_dir, "attach_test")
               )

      assert :test_handler in LokiLoggerHandler.list_handlers()
    end

    test "returns error for missing loki_url" do
      assert {:error, {:handler_not_added, {:missing_config, :loki_url}}} =
               LokiLoggerHandler.attach(:bad_handler, data_dir: @test_dir)
    end
  end

  describe "detach/1" do
    test "detaches a handler successfully", %{url: url} do
      LokiLoggerHandler.attach(:detach_test,
        loki_url: url,
        data_dir: Path.join(@test_dir, "detach_test")
      )

      assert :ok = LokiLoggerHandler.detach(:detach_test)
      refute :detach_test in LokiLoggerHandler.list_handlers()
    end

    test "returns error for non-existent handler" do
      assert {:error, _} = LokiLoggerHandler.detach(:nonexistent)
    end
  end

  describe "logging integration" do
    test "logs are sent to Loki", %{fake: fake, url: url} do
      LokiLoggerHandler.attach(:log_test,
        loki_url: url,
        data_dir: Path.join(@test_dir, "log_test"),
        batch_interval_ms: 100,
        labels: %{level: :level, app: {:static, "test_app"}}
      )

      # Log a message
      Logger.info("Test message from integration test")

      # Wait for batch to be sent
      Process.sleep(300)

      # Check that the log was received
      entries = FakeLoki.get_entries(fake)
      assert length(entries) >= 1

      # Check the content
      values = FakeLoki.get_log_values(fake)
      messages = Enum.map(values, fn {_ts, msg, _meta} -> msg end)
      assert Enum.any?(messages, &String.contains?(&1, "Test message from integration test"))
    end

    test "labels are correctly extracted", %{fake: fake, url: url} do
      LokiLoggerHandler.attach(:label_test,
        loki_url: url,
        data_dir: Path.join(@test_dir, "label_test"),
        batch_interval_ms: 100,
        labels: %{
          level: :level,
          app: {:static, "label_test_app"}
        }
      )

      Logger.warning("Warning message")
      Process.sleep(300)

      entries = FakeLoki.get_entries(fake)
      assert length(entries) >= 1

      # Check that the stream has correct labels
      [%{"streams" => streams} | _] = entries
      stream = hd(streams)
      labels = stream["stream"]

      assert labels["level"] == "warning"
      assert labels["app"] == "label_test_app"
    end

    test "structured metadata is included", %{fake: fake, url: url} do
      LokiLoggerHandler.attach(:metadata_test,
        loki_url: url,
        data_dir: Path.join(@test_dir, "metadata_test"),
        batch_interval_ms: 100,
        labels: %{level: :level},
        structured_metadata: [:request_id, :user_id]
      )

      Logger.info("Request handled", request_id: "req-123", user_id: "user-456")
      Process.sleep(300)

      values = FakeLoki.get_log_values(fake)

      # Find the entry with structured metadata
      entry_with_meta = Enum.find(values, fn {_ts, _msg, meta} -> meta != nil end)
      assert entry_with_meta != nil

      {_ts, _msg, meta} = entry_with_meta
      assert meta["request_id"] == "req-123"
      assert meta["user_id"] == "user-456"
    end
  end

  describe "flush/1" do
    test "forces immediate send", %{fake: fake, url: url} do
      :ok =
        LokiLoggerHandler.attach(:flush_test,
          loki_url: url,
          data_dir: Path.join(@test_dir, "flush_test"),
          # Long interval so it won't auto-send
          batch_interval_ms: 60_000,
          labels: %{level: :level}
        )

      # Give time for processes to start
      Process.sleep(100)

      Logger.info("Flush test message")

      # Give time for the log to be processed
      Process.sleep(100)

      # Should be no entries yet (batch interval is long)
      assert FakeLoki.get_entries(fake) == []

      # Force flush
      assert :ok = LokiLoggerHandler.flush(:flush_test)

      # Now entries should be present
      entries = FakeLoki.get_entries(fake)
      assert length(entries) >= 1
    end
  end

  describe "multiple handlers" do
    test "multiple handlers can be attached", %{url: url} do
      LokiLoggerHandler.attach(:multi_1,
        loki_url: url,
        data_dir: Path.join(@test_dir, "multi_1"),
        labels: %{handler: {:static, "one"}}
      )

      LokiLoggerHandler.attach(:multi_2,
        loki_url: url,
        data_dir: Path.join(@test_dir, "multi_2"),
        labels: %{handler: {:static, "two"}}
      )

      handlers = LokiLoggerHandler.list_handlers()
      assert :multi_1 in handlers
      assert :multi_2 in handlers
    end
  end

  describe "get_config/1" do
    test "returns handler configuration", %{url: url} do
      LokiLoggerHandler.attach(:config_test,
        loki_url: url,
        data_dir: Path.join(@test_dir, "config_test"),
        batch_size: 50
      )

      {:ok, config} = LokiLoggerHandler.get_config(:config_test)

      assert config.loki_url == url
      assert config.batch_size == 50
    end
  end
end
