defmodule LokiLoggerHandler.HandlerTest do
  use ExUnit.Case, async: false

  alias LokiLoggerHandler.FakeLoki
  alias LokiLoggerHandler.Storage.{Cub, Ets}

  @test_dir "test/tmp/handler_test"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      # Clean up any handlers
      for handler_id <- LokiLoggerHandler.list_handlers() do
        LokiLoggerHandler.detach(handler_id)
      end

      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  # Helper to check if a process is registered via Registry
  defp process_registered?(module, handler_id) do
    case Registry.lookup(LokiLoggerHandler.Registry, {module, handler_id}) do
      [{_pid, _value}] -> true
      [] -> false
    end
  end

  describe "changing_config/3 with :set" do
    test "replaces config while preserving internal values" do
      {:ok, fake} = FakeLoki.start_link(port: 4500)
      url = FakeLoki.url(fake)

      # Attach handler
      :ok =
        LokiLoggerHandler.attach(:config_set_test,
          loki_url: url,
          data_dir: Path.join(@test_dir, "config_set"),
          batch_size: 50,
          labels: %{level: :level}
        )

      # Verify processes are running (registered via Registry)
      assert process_registered?(Cub, :config_set_test)
      assert process_registered?(LokiLoggerHandler.Sender, :config_set_test)

      # Use :logger.set_handler_config to trigger changing_config(:set, ...)
      :ok =
        :logger.set_handler_config(:config_set_test, :config, %{
          loki_url: url,
          batch_size: 100,
          labels: %{app: {:static, "newapp"}}
        })

      # Verify config was updated
      {:ok, config_after} = LokiLoggerHandler.get_config(:config_set_test)
      assert config_after.batch_size == 100
      assert config_after.labels == %{app: {:static, "newapp"}}

      # Processes should still be running (internal names preserved)
      assert process_registered?(Cub, :config_set_test)
      assert process_registered?(LokiLoggerHandler.Sender, :config_set_test)

      FakeLoki.stop(fake)
    end

    test "validates new config on :set" do
      {:ok, fake} = FakeLoki.start_link(port: 4501)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:config_set_validate,
          loki_url: url,
          data_dir: Path.join(@test_dir, "config_set_validate")
        )

      # Try to set config without loki_url - should fail
      result =
        :logger.set_handler_config(:config_set_validate, :config, %{
          batch_size: 100
        })

      assert {:error, {:missing_config, :loki_url}} = result

      FakeLoki.stop(fake)
    end
  end

  describe "changing_config/3 with :update" do
    test "merges new config with existing config" do
      {:ok, fake} = FakeLoki.start_link(port: 4502)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:config_update_test,
          loki_url: url,
          data_dir: Path.join(@test_dir, "config_update"),
          batch_size: 50,
          batch_interval_ms: 1000
        )

      # Use update_config which triggers changing_config(:update, ...)
      :ok = LokiLoggerHandler.update_config(:config_update_test, batch_size: 200)

      {:ok, config} = LokiLoggerHandler.get_config(:config_update_test)

      # Updated value
      assert config.batch_size == 200
      # Original value preserved
      assert config.batch_interval_ms == 1000
      # Required value still present
      assert config.loki_url == url

      FakeLoki.stop(fake)
    end

    test "validates merged config on :update" do
      {:ok, fake} = FakeLoki.start_link(port: 4503)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:config_update_validate,
          loki_url: url,
          data_dir: Path.join(@test_dir, "config_update_validate")
        )

      # Try to update with invalid loki_url type
      result = LokiLoggerHandler.update_config(:config_update_validate, loki_url: 12345)

      assert {:error, {:invalid_config, :loki_url, "must be a string"}} = result

      FakeLoki.stop(fake)
    end
  end

  describe "filter_config/1" do
    test "removes internal keys from config" do
      {:ok, fake} = FakeLoki.start_link(port: 4504)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:filter_config_test,
          loki_url: url,
          data_dir: Path.join(@test_dir, "filter_config"),
          batch_size: 75
        )

      # Get handler config directly from :logger (which calls filter_config)
      {:ok, handler_config} = :logger.get_handler_config(:filter_config_test)

      # The config should have user-visible keys
      assert handler_config.config.loki_url == url
      assert handler_config.config.batch_size == 75

      # But internal keys should be filtered out
      refute Map.has_key?(handler_config.config, :storage_name)
      refute Map.has_key?(handler_config.config, :sender_name)

      FakeLoki.stop(fake)
    end
  end

  describe "validate_config/1" do
    test "rejects non-string loki_url" do
      result =
        LokiLoggerHandler.attach(:invalid_url_type,
          loki_url: 12345,
          data_dir: Path.join(@test_dir, "invalid_url")
        )

      assert {:error, {:handler_not_added, {:invalid_config, :loki_url, "must be a string"}}} =
               result
    end

    test "rejects missing loki_url" do
      result =
        LokiLoggerHandler.attach(:missing_url,
          data_dir: Path.join(@test_dir, "missing_url")
        )

      assert {:error, {:handler_not_added, {:missing_config, :loki_url}}} = result
    end

    test "accepts atom loki_url converted to string is still invalid" do
      result =
        LokiLoggerHandler.attach(:atom_url,
          loki_url: :not_a_string,
          data_dir: Path.join(@test_dir, "atom_url")
        )

      assert {:error, {:handler_not_added, {:invalid_config, :loki_url, "must be a string"}}} =
               result
    end
  end

  describe "adding_handler/1 error paths" do
    test "returns error when storage fails to start" do
      # Use an invalid data_dir path that will cause CubDB to fail
      # On most systems, trying to create a directory under /dev/null will fail
      result =
        LokiLoggerHandler.attach(:storage_fail_test,
          loki_url: "http://localhost:3100",
          data_dir: "/dev/null/impossible/path"
        )

      assert {:error, {:handler_not_added, {:supervisor_start_failed, _reason}}} = result
    end
  end

  describe "removing_handler/1" do
    test "cleans up storage and sender processes" do
      {:ok, fake} = FakeLoki.start_link(port: 4505)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:remove_test,
          loki_url: url,
          data_dir: Path.join(@test_dir, "remove_test")
        )

      # Verify processes are running
      assert process_registered?(Cub, :remove_test)
      assert process_registered?(LokiLoggerHandler.Sender, :remove_test)

      # Detach handler
      :ok = LokiLoggerHandler.detach(:remove_test)

      # Processes should be stopped
      Process.sleep(50)
      refute process_registered?(Cub, :remove_test)
      refute process_registered?(LokiLoggerHandler.Sender, :remove_test)

      FakeLoki.stop(fake)
    end

    test "handles already-stopped processes gracefully" do
      {:ok, fake} = FakeLoki.start_link(port: 4506)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:remove_stopped_test,
          loki_url: url,
          data_dir: Path.join(@test_dir, "remove_stopped")
        )

      # Manually stop the sender via Registry before detaching
      sender = LokiLoggerHandler.Application.via(LokiLoggerHandler.Sender, :remove_stopped_test)
      GenServer.stop(sender)

      # Detach should still work without error
      :ok = LokiLoggerHandler.detach(:remove_stopped_test)

      FakeLoki.stop(fake)
    end
  end

  describe "log/2" do
    test "uses default labels when not configured" do
      {:ok, fake} = FakeLoki.start_link(port: 4507)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:default_labels_test,
          loki_url: url,
          data_dir: Path.join(@test_dir, "default_labels"),
          batch_interval_ms: 100
          # Note: no labels configured, should use default %{level: :level}
        )

      require Logger
      Logger.info("Test with default labels")

      Process.sleep(200)

      entries = FakeLoki.get_entries(fake)
      assert length(entries) >= 1

      # Check that default label (level) was used
      [%{"streams" => [stream | _]} | _] = entries
      assert stream["stream"]["level"] == "info"

      FakeLoki.stop(fake)
    end
  end

  describe "memory storage strategy" do
    test "attach with storage: :memory starts ETS-based storage" do
      {:ok, fake} = FakeLoki.start_link(port: 4508)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:memory_storage_test,
          loki_url: url,
          storage: :memory,
          batch_interval_ms: 100
        )

      # Verify processes are running
      assert process_registered?(Ets, :memory_storage_test)
      assert process_registered?(LokiLoggerHandler.Sender, :memory_storage_test)

      # Verify storage is set to :memory in config
      {:ok, config} = LokiLoggerHandler.get_config(:memory_storage_test)
      assert config.storage == :memory

      FakeLoki.stop(fake)
    end

    test "memory storage logs are sent to Loki" do
      {:ok, fake} = FakeLoki.start_link(port: 4509)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:memory_log_test,
          loki_url: url,
          storage: :memory,
          batch_interval_ms: 100,
          labels: %{level: :level, app: {:static, "memory_test"}}
        )

      require Logger
      Logger.info("Memory storage test message")

      Process.sleep(200)

      entries = FakeLoki.get_entries(fake)
      assert length(entries) >= 1

      [%{"streams" => [stream | _]} | _] = entries
      assert stream["stream"]["app"] == "memory_test"

      FakeLoki.stop(fake)
    end

    test "detach cleans up memory storage processes" do
      {:ok, fake} = FakeLoki.start_link(port: 4510)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:memory_detach_test,
          loki_url: url,
          storage: :memory
        )

      assert process_registered?(Ets, :memory_detach_test)
      assert process_registered?(LokiLoggerHandler.Sender, :memory_detach_test)

      :ok = LokiLoggerHandler.detach(:memory_detach_test)

      Process.sleep(50)
      refute process_registered?(Ets, :memory_detach_test)
      refute process_registered?(LokiLoggerHandler.Sender, :memory_detach_test)

      FakeLoki.stop(fake)
    end

    test "flush works with memory storage" do
      {:ok, fake} = FakeLoki.start_link(port: 4511)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:memory_flush_test,
          loki_url: url,
          storage: :memory,
          batch_interval_ms: 60_000
        )

      require Logger
      Logger.info("Memory flush test message")

      # Wait for log to be processed
      Process.sleep(50)

      # Flush immediately instead of waiting for interval
      :ok = LokiLoggerHandler.flush(:memory_flush_test)

      entries = FakeLoki.get_entries(fake)
      assert length(entries) >= 1

      FakeLoki.stop(fake)
    end

    test "config update preserves memory storage setting" do
      {:ok, fake} = FakeLoki.start_link(port: 4512)
      url = FakeLoki.url(fake)

      :ok =
        LokiLoggerHandler.attach(:memory_update_test,
          loki_url: url,
          storage: :memory,
          batch_size: 50
        )

      :ok = LokiLoggerHandler.update_config(:memory_update_test, batch_size: 100)

      {:ok, config} = LokiLoggerHandler.get_config(:memory_update_test)
      assert config.storage == :memory
      assert config.batch_size == 100

      FakeLoki.stop(fake)
    end
  end
end
