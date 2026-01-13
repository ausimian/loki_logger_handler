defmodule LokiLoggerHandler.StorageTest do
  use ExUnit.Case, async: false

  alias LokiLoggerHandler.Storage.Cub
  alias LokiLoggerHandler.Storage.Ets

  @test_dir "test/tmp/storage_test"

  setup do
    # Clean up test directory
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  # CubDB-specific tests
  describe "Cub.start_link/1" do
    test "starts a storage process" do
      {:ok, pid} = Cub.start_link(name: :test_cub_storage, data_dir: @test_dir)
      assert Process.alive?(pid)
      Cub.stop(:test_cub_storage)
    end

    test "creates data directory if it doesn't exist" do
      nested_dir = Path.join(@test_dir, "nested/path")
      {:ok, _pid} = Cub.start_link(name: :test_cub_storage_nested, data_dir: nested_dir)
      assert File.dir?(nested_dir)
      Cub.stop(:test_cub_storage_nested)
    end
  end

  # ETS-specific tests
  describe "Ets.start_link/1" do
    test "starts a storage process" do
      {:ok, pid} = Ets.start_link(name: :test_ets_storage)
      assert Process.alive?(pid)
      Ets.stop(:test_ets_storage)
    end
  end

  # Helper to start storage with the right options per strategy
  defp start_storage(strategy, name, dir, extra_opts \\ [])

  defp start_storage(:disk, name, dir, extra_opts) do
    opts = [name: name, data_dir: dir] ++ extra_opts
    Cub.start_link(opts)
  end

  defp start_storage(:memory, name, _dir, extra_opts) do
    opts = [name: name] ++ extra_opts
    Ets.start_link(opts)
  end

  # Helper to get the storage module for a strategy
  defp storage_module(:disk), do: Cub
  defp storage_module(:memory), do: Ets

  # Parameterized tests for both storage strategies
  for strategy <- [:disk, :memory] do
    @strategy strategy

    describe "#{@strategy} storage - store/2" do
      setup do
        strategy = unquote(strategy)
        mod = storage_module(strategy)
        dir = Path.join(@test_dir, "#{strategy}_store")
        {:ok, _pid} = start_storage(strategy, :test_storage, dir)
        on_exit(fn -> catch_exit(mod.stop(:test_storage)) end)
        %{storage_name: :test_storage, mod: mod}
      end

      test "stores an entry (fire-and-forget)", %{storage_name: storage, mod: mod} do
        entry = %{
          timestamp: System.system_time(:nanosecond),
          level: :info,
          message: "test message",
          labels: %{"level" => "info"},
          structured_metadata: %{}
        }

        assert :ok = mod.store(storage, entry)

        # Wait for cast to be processed
        Process.sleep(10)

        # Verify entry was stored by fetching it
        batch = mod.fetch_batch(storage, 1)
        assert length(batch) == 1
        [{key, stored_entry}] = batch
        assert is_tuple(key)
        assert tuple_size(key) == 2
        assert stored_entry.message == "test message"
      end

      test "entries are ordered by key", %{storage_name: storage, mod: mod} do
        entries =
          for i <- 1..5 do
            entry = %{
              timestamp: i,
              level: :info,
              message: "message #{i}",
              labels: %{},
              structured_metadata: %{}
            }

            :ok = mod.store(storage, entry)
            entry
          end

        # Wait for casts to be processed
        Process.sleep(10)

        fetched = mod.fetch_batch(storage, 10)
        fetched_messages = Enum.map(fetched, fn {_key, entry} -> entry.message end)

        assert fetched_messages == Enum.map(entries, & &1.message)
      end
    end

    describe "#{@strategy} storage - fetch_batch/2" do
      setup do
        strategy = unquote(strategy)
        mod = storage_module(strategy)
        dir = Path.join(@test_dir, "#{strategy}_fetch")
        {:ok, _pid} = start_storage(strategy, :test_storage, dir)
        on_exit(fn -> catch_exit(mod.stop(:test_storage)) end)
        %{storage_name: :test_storage, mod: mod}
      end

      test "returns empty list when no entries", %{storage_name: storage, mod: mod} do
        assert mod.fetch_batch(storage, 10) == []
      end

      test "returns entries up to limit", %{storage_name: storage, mod: mod} do
        for i <- 1..10 do
          mod.store(storage, %{
            timestamp: i,
            level: :info,
            message: "msg #{i}",
            labels: %{},
            structured_metadata: %{}
          })
        end

        # Wait for casts to be processed
        Process.sleep(10)

        batch = mod.fetch_batch(storage, 5)
        assert length(batch) == 5
      end
    end

    describe "#{@strategy} storage - delete_up_to/2" do
      setup do
        strategy = unquote(strategy)
        mod = storage_module(strategy)
        dir = Path.join(@test_dir, "#{strategy}_delete")
        {:ok, _pid} = start_storage(strategy, :test_storage, dir)
        on_exit(fn -> catch_exit(mod.stop(:test_storage)) end)
        %{storage_name: :test_storage, mod: mod}
      end

      test "deletes entries up to and including the key", %{storage_name: storage, mod: mod} do
        for i <- 1..5 do
          mod.store(storage, %{
            timestamp: i,
            level: :info,
            message: "msg #{i}",
            labels: %{},
            structured_metadata: %{}
          })
        end

        # Wait for casts to be processed
        Process.sleep(10)

        # Get all entries and their keys
        all_entries = mod.fetch_batch(storage, 10)
        assert length(all_entries) == 5

        # Delete first 3 entries
        {third_key, _} = Enum.at(all_entries, 2)
        mod.delete_up_to(storage, third_key)

        remaining = mod.fetch_batch(storage, 10)
        assert length(remaining) == 2
      end
    end

    describe "#{@strategy} storage - count/1" do
      setup do
        strategy = unquote(strategy)
        mod = storage_module(strategy)
        dir = Path.join(@test_dir, "#{strategy}_count")
        {:ok, _pid} = start_storage(strategy, :test_storage, dir)
        on_exit(fn -> catch_exit(mod.stop(:test_storage)) end)
        %{storage_name: :test_storage, mod: mod}
      end

      test "returns 0 when empty", %{storage_name: storage, mod: mod} do
        assert mod.count(storage) == 0
      end

      test "returns correct count after storing entries", %{storage_name: storage, mod: mod} do
        for i <- 1..7 do
          mod.store(storage, %{
            timestamp: i,
            level: :info,
            message: "msg #{i}",
            labels: %{},
            structured_metadata: %{}
          })
        end

        # Wait for casts to be processed
        Process.sleep(10)

        assert mod.count(storage) == 7
      end
    end

    describe "#{@strategy} storage - max_buffer_size" do
      test "drops oldest entries when buffer is full" do
        strategy = unquote(strategy)
        mod = storage_module(strategy)
        dir = Path.join(@test_dir, "#{strategy}_small_buffer")
        storage_name = :"small_buffer_#{strategy}"

        {:ok, _pid} = start_storage(strategy, storage_name, dir, max_buffer_size: 20)

        # Store 25 entries (should trigger drop when we hit 20)
        for i <- 1..25 do
          mod.store(storage_name, %{
            timestamp: i,
            level: :info,
            message: "msg #{i}",
            labels: %{},
            structured_metadata: %{}
          })
        end

        # Wait for casts to be processed
        Process.sleep(20)

        # Should have dropped oldest 10% (2 entries) when we hit 20
        count = mod.count(storage_name)
        # After first drop at 20, we continue adding, so final count varies
        assert count < 25

        mod.stop(storage_name)
      end
    end
  end
end
