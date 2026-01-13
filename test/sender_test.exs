defmodule LokiLoggerHandler.SenderTest do
  use ExUnit.Case,
    async: false,
    parameterize: [
      %{strategy: :disk, mod: LokiLoggerHandler.Storage.Cub},
      %{strategy: :memory, mod: LokiLoggerHandler.Storage.Ets}
    ]

  alias LokiLoggerHandler.{Sender, FakeLoki}
  alias LokiLoggerHandler.Storage.{Cub, Ets}

  @test_dir "test/tmp/sender_test"

  setup %{strategy: strategy, mod: mod} do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    %{strategy: strategy, mod: mod}
  end

  # Helper to start storage with the right options per strategy
  defp start_storage(:disk, name, dir) do
    Cub.start_link(name: name, data_dir: dir)
    {:ok, name}
  end

  defp start_storage(:memory, name, _dir) do
    Ets.start_link(name: name)
    {:ok, name}
  end

  defp sample_entry(message) do
    %{
      timestamp: System.system_time(:nanosecond),
      level: :info,
      message: message,
      labels: %{"level" => "info"},
      structured_metadata: %{}
    }
  end

  describe "start_link/1" do
    test "starts a sender process with required options", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_start_link_test")
      storage_name = :"storage_#{strategy}_start_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_start_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake)
        )

      assert Process.alive?(pid)

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end

    test "uses default values for optional parameters", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_defaults_test")
      storage_name = :"storage_#{strategy}_defaults_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_defaults_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake)
        )

      state = Sender.get_state(pid)

      assert state.batch_size == 100
      assert state.batch_interval_ms == 5_000
      assert state.backoff_base_ms == 1_000
      assert state.backoff_max_ms == 60_000
      assert state.consecutive_failures == 0

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end
  end

  describe "get_state/1" do
    test "returns current state as a map", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_get_state_test")
      storage_name = :"storage_#{strategy}_state_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      sender_name = :"test_sender_state_#{strategy}_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Sender.start_link(
          name: sender_name,
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake),
          batch_size: 50,
          batch_interval_ms: 1000
        )

      state = Sender.get_state(pid)

      assert is_map(state)
      assert state.name == sender_name
      assert state.batch_size == 50
      assert state.batch_interval_ms == 1000
      assert state.loki_url == FakeLoki.url(fake)
      assert is_reference(state.timer_ref)

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end
  end

  describe "flush/1" do
    test "sends all pending entries immediately", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_flush_test")
      storage_name = :"storage_#{strategy}_flush_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_flush_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake),
          batch_interval_ms: 60_000
        )

      # Add entries to storage
      for i <- 1..5 do
        mod.store(storage, sample_entry("message #{i}"))
      end

      # Wait for casts to be processed
      Process.sleep(20)

      assert mod.count(storage) == 5

      # Flush should send all entries
      assert :ok = Sender.flush(pid)

      # Entries should be sent and deleted from storage
      assert mod.count(storage) == 0

      # FakeLoki should have received them
      entries = FakeLoki.get_entries(fake)
      assert length(entries) >= 1

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end

    test "returns :ok when storage is empty", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_flush_empty_test")
      storage_name = :"storage_#{strategy}_flush_empty_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_flush_empty_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake)
        )

      assert mod.count(storage) == 0
      assert :ok = Sender.flush(pid)

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end

    test "returns error when Loki is unavailable", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_flush_error_test")
      storage_name = :"storage_#{strategy}_flush_error_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_flush_error_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          # No server listening on this port
          loki_url: "http://localhost:59998"
        )

      mod.store(storage, sample_entry("test message"))
      Process.sleep(10)

      result = Sender.flush(pid)
      assert {:error, {:request_failed, _}} = result

      # Entry should still be in storage (not deleted on failure)
      assert mod.count(storage) == 1

      GenServer.stop(pid)
      mod.stop(storage)
    end
  end

  describe "exponential backoff" do
    test "increments consecutive_failures on send failure", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_backoff_test")
      storage_name = :"storage_#{strategy}_backoff_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_backoff_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: "http://localhost:59997",
          batch_interval_ms: 60_000
        )

      mod.store(storage, sample_entry("test"))
      Process.sleep(10)

      state_before = Sender.get_state(pid)
      assert state_before.consecutive_failures == 0

      # Flush will fail because no server is listening
      {:error, _} = Sender.flush(pid)

      state_after = Sender.get_state(pid)
      assert state_after.consecutive_failures == 1

      # Fail again
      {:error, _} = Sender.flush(pid)

      state_after_2 = Sender.get_state(pid)
      assert state_after_2.consecutive_failures == 2

      GenServer.stop(pid)
      mod.stop(storage)
    end

    test "resets consecutive_failures on successful send", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_backoff_reset_test")
      storage_name = :"storage_#{strategy}_backoff_reset_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_backoff_reset_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake),
          batch_interval_ms: 60_000
        )

      mod.store(storage, sample_entry("test"))
      Process.sleep(10)

      # Successful flush
      assert :ok = Sender.flush(pid)

      state = Sender.get_state(pid)
      assert state.consecutive_failures == 0

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end
  end

  describe "automatic batch sending" do
    test "sends batch when timer fires and entries exist", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_auto_batch_test")
      storage_name = :"storage_#{strategy}_auto_batch_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_auto_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake),
          batch_interval_ms: 100
        )

      # Add entries
      for i <- 1..3 do
        mod.store(storage, sample_entry("auto message #{i}"))
      end

      # Wait for automatic batch
      Process.sleep(250)

      # Entries should have been sent
      assert mod.count(storage) == 0
      assert length(FakeLoki.get_entries(fake)) >= 1

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end

    test "does not send when storage is empty", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_no_send_empty_test")
      storage_name = :"storage_#{strategy}_no_send_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      sender_name = :"test_sender_no_send_#{strategy}_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Sender.start_link(
          name: sender_name,
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake),
          batch_interval_ms: 50
        )

      # Wait for several batch intervals
      Process.sleep(200)

      # No entries should have been sent (none existed)
      assert FakeLoki.get_entries(fake) == []

      GenServer.stop(sender_name)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end

    test "respects batch_size limit", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_batch_size_test")
      storage_name = :"storage_#{strategy}_batch_size_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_batch_size_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake),
          batch_size: 3,
          batch_interval_ms: 100
        )

      # Add more entries than batch size
      for i <- 1..10 do
        mod.store(storage, sample_entry("batch message #{i}"))
      end

      # Wait for batches to be sent
      Process.sleep(650)

      assert mod.count(storage) == 0

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end
  end

  describe "backoff timing" do
    test "uses normal interval when no failures", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_interval_normal_test")
      storage_name = :"storage_#{strategy}_interval_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_interval_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake),
          batch_interval_ms: 100,
          backoff_base_ms: 1000
        )

      state = Sender.get_state(pid)
      assert state.consecutive_failures == 0

      # The timer should fire at normal interval (100ms)
      mod.store(storage, sample_entry("test"))
      Process.sleep(200)

      assert mod.count(storage) == 0

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end

    test "applies exponential backoff after failures", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_backoff_exp_test")
      storage_name = :"storage_#{strategy}_exp_backoff_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_exp_backoff_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: "http://localhost:59996",
          batch_interval_ms: 50,
          backoff_base_ms: 100,
          backoff_max_ms: 1000
        )

      # Add an entry and let it fail a few times
      mod.store(storage, sample_entry("backoff test"))

      # Wait for a couple batch cycles to accumulate failures
      Process.sleep(300)

      state = Sender.get_state(pid)
      # Should have some failures by now
      assert state.consecutive_failures > 0

      GenServer.stop(pid)
      mod.stop(storage)
    end

    test "caps backoff at max_backoff_ms", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_backoff_cap_test")
      storage_name = :"storage_#{strategy}_cap_backoff_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_cap_backoff_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: "http://localhost:59995",
          batch_interval_ms: 60_000,
          backoff_base_ms: 50,
          backoff_max_ms: 100
        )

      # Add entry and cause many failures
      mod.store(storage, sample_entry("cap test"))
      Process.sleep(10)

      # Let it fail multiple times
      for _ <- 1..5 do
        {:error, _} = Sender.flush(pid)
      end

      state = Sender.get_state(pid)
      assert state.consecutive_failures == 5

      GenServer.stop(pid)
      mod.stop(storage)
    end
  end

  describe "batch_check timer" do
    test "continues scheduling after empty check", %{strategy: strategy, mod: mod} do
      dir = Path.join(@test_dir, "#{strategy}_timer_continue_test")
      storage_name = :"storage_#{strategy}_timer_#{System.unique_integer([:positive])}"
      {:ok, storage} = start_storage(strategy, storage_name, dir)
      {:ok, fake} = FakeLoki.start_link()

      {:ok, pid} =
        Sender.start_link(
          name: :"test_sender_timer_#{strategy}_#{System.unique_integer([:positive])}",
          storage: storage,
          storage_module: mod,
          loki_url: FakeLoki.url(fake),
          batch_interval_ms: 50
        )

      # Let several empty batch checks happen
      Process.sleep(200)

      # Now add an entry - should still be sent on next timer
      mod.store(storage, sample_entry("delayed entry"))
      Process.sleep(100)

      assert mod.count(storage) == 0
      assert length(FakeLoki.get_entries(fake)) >= 1

      GenServer.stop(pid)
      mod.stop(storage)
      FakeLoki.stop(fake)
    end
  end
end
