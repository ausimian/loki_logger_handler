defmodule LokiLoggerHandler.StorageTest do
  use ExUnit.Case, async: false

  alias LokiLoggerHandler.Storage

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

  describe "start_link/1" do
    test "starts a storage process" do
      {:ok, pid} = Storage.start_link(name: :test_storage, data_dir: @test_dir)
      assert Process.alive?(pid)
      Storage.stop(:test_storage)
    end

    test "creates data directory if it doesn't exist" do
      nested_dir = Path.join(@test_dir, "nested/path")
      {:ok, _pid} = Storage.start_link(name: :test_storage_nested, data_dir: nested_dir)
      assert File.dir?(nested_dir)
      Storage.stop(:test_storage_nested)
    end
  end

  describe "store/2" do
    setup do
      {:ok, _pid} = Storage.start_link(name: :test_storage, data_dir: @test_dir)
      on_exit(fn -> catch_exit(Storage.stop(:test_storage)) end)
      :ok
    end

    test "stores an entry and returns a key" do
      entry = %{
        timestamp: System.system_time(:nanosecond),
        level: :info,
        message: "test message",
        labels: %{"level" => "info"},
        structured_metadata: %{}
      }

      {:ok, key} = Storage.store(:test_storage, entry)
      assert is_tuple(key)
      assert tuple_size(key) == 2
    end

    test "entries are ordered by key" do
      entries =
        for i <- 1..5 do
          entry = %{
            timestamp: i,
            level: :info,
            message: "message #{i}",
            labels: %{},
            structured_metadata: %{}
          }

          {:ok, _key} = Storage.store(:test_storage, entry)
          entry
        end

      fetched = Storage.fetch_batch(:test_storage, 10)
      fetched_messages = Enum.map(fetched, fn {_key, entry} -> entry.message end)

      assert fetched_messages == Enum.map(entries, & &1.message)
    end
  end

  describe "fetch_batch/2" do
    setup do
      {:ok, _pid} = Storage.start_link(name: :test_storage, data_dir: @test_dir)
      on_exit(fn -> catch_exit(Storage.stop(:test_storage)) end)
      :ok
    end

    test "returns empty list when no entries" do
      assert Storage.fetch_batch(:test_storage, 10) == []
    end

    test "returns entries up to limit" do
      for i <- 1..10 do
        Storage.store(:test_storage, %{
          timestamp: i,
          level: :info,
          message: "msg #{i}",
          labels: %{},
          structured_metadata: %{}
        })
      end

      batch = Storage.fetch_batch(:test_storage, 5)
      assert length(batch) == 5
    end
  end

  describe "delete_up_to/2" do
    setup do
      {:ok, _pid} = Storage.start_link(name: :test_storage, data_dir: @test_dir)
      on_exit(fn -> catch_exit(Storage.stop(:test_storage)) end)
      :ok
    end

    test "deletes entries up to and including the key" do
      keys =
        for i <- 1..5 do
          {:ok, key} =
            Storage.store(:test_storage, %{
              timestamp: i,
              level: :info,
              message: "msg #{i}",
              labels: %{},
              structured_metadata: %{}
            })

          key
        end

      # Delete first 3 entries
      third_key = Enum.at(keys, 2)
      Storage.delete_up_to(:test_storage, third_key)

      remaining = Storage.fetch_batch(:test_storage, 10)
      assert length(remaining) == 2
    end
  end

  describe "count/1" do
    setup do
      {:ok, _pid} = Storage.start_link(name: :test_storage, data_dir: @test_dir)
      on_exit(fn -> catch_exit(Storage.stop(:test_storage)) end)
      :ok
    end

    test "returns 0 when empty" do
      assert Storage.count(:test_storage) == 0
    end

    test "returns correct count after storing entries" do
      for i <- 1..7 do
        Storage.store(:test_storage, %{
          timestamp: i,
          level: :info,
          message: "msg #{i}",
          labels: %{},
          structured_metadata: %{}
        })
      end

      assert Storage.count(:test_storage) == 7
    end
  end

  describe "max_buffer_size" do
    test "drops oldest entries when buffer is full" do
      dir = Path.join(@test_dir, "small_buffer")

      {:ok, _pid} =
        Storage.start_link(
          name: :small_buffer_storage,
          data_dir: dir,
          max_buffer_size: 20
        )

      # Store 25 entries (should trigger drop when we hit 20)
      for i <- 1..25 do
        Storage.store(:small_buffer_storage, %{
          timestamp: i,
          level: :info,
          message: "msg #{i}",
          labels: %{},
          structured_metadata: %{}
        })
      end

      # Should have dropped oldest 10% (2 entries) when we hit 20
      count = Storage.count(:small_buffer_storage)
      # After first drop at 20, we continue adding, so final count varies
      assert count < 25

      Storage.stop(:small_buffer_storage)
    end
  end
end
