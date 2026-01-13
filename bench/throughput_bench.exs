# Throughput benchmark for LokiLoggerHandler
#
# Run with: mix run bench/throughput_bench.exs
#
# This benchmark measures:
# 1. Storage write throughput (CubDB performance)
# 2. Full pipeline throughput (store -> batch -> send -> delete)

# Compile the counting endpoint
Code.compile_file("bench/support/counting_endpoint.ex")

alias LokiLoggerHandler.Bench.CountingEndpoint
alias LokiLoggerHandler.{Storage, Sender, Formatter}

# Configuration
batch_size = 50
messages_per_iteration = 10

# Sample log entry for benchmarking
sample_event = %{
  level: :info,
  msg: {:string, "Benchmark test message with some realistic content"},
  meta: %{
    time: System.system_time(:microsecond),
    mfa: {MyApp.Module, :function, 2},
    file: "lib/my_app/module.ex",
    line: 42,
    request_id: "req-123",
    user_id: "user-456"
  }
}

labels = %{level: :level, app: {:static, "benchmark"}}
structured_metadata = [:request_id, :user_id]

# Pre-format entry to isolate storage performance
formatted_entry = Formatter.format(sample_event, labels, structured_metadata)

# Setup for storage-only benchmark
storage_dir = Path.join(System.tmp_dir!(), "loki_bench_storage_#{System.unique_integer()}")
File.mkdir_p!(storage_dir)

{:ok, storage} =
  Storage.start_link(
    name: :bench_storage,
    data_dir: storage_dir,
    max_buffer_size: 100_000
  )

# Setup for full pipeline benchmark
{:ok, endpoint} = CountingEndpoint.start_link(port: 4999)
endpoint_url = CountingEndpoint.url(endpoint)

pipeline_dir = Path.join(System.tmp_dir!(), "loki_bench_pipeline_#{System.unique_integer()}")
File.mkdir_p!(pipeline_dir)

{:ok, pipeline_storage} =
  Storage.start_link(
    name: :bench_pipeline_storage,
    data_dir: pipeline_dir,
    max_buffer_size: 100_000
  )

{:ok, sender} =
  Sender.start_link(
    name: :bench_sender,
    storage: :bench_pipeline_storage,
    loki_url: endpoint_url,
    batch_size: batch_size,
    batch_interval_ms: 60_000,
    backoff_base_ms: 1_000,
    backoff_max_ms: 60_000
  )

IO.puts("\nBenchmarking with:")
IO.puts("  - batch_size: #{batch_size}")
IO.puts("  - messages_per_iteration: #{messages_per_iteration}")
IO.puts("  - endpoint: #{endpoint_url}")
IO.puts("")

Benchee.run(
  %{
    "Storage.store (single)" => fn ->
      Storage.store(storage, formatted_entry)
    end,
    "Storage.store (#{messages_per_iteration}x)" => fn ->
      for _ <- 1..messages_per_iteration do
        Storage.store(storage, formatted_entry)
      end
    end,
    "Full pipeline (#{messages_per_iteration}x store + flush)" => {
      fn ->
        for _ <- 1..messages_per_iteration do
          Storage.store(pipeline_storage, formatted_entry)
        end

        Sender.flush(sender)
      end,
      before_scenario: fn input ->
        CountingEndpoint.reset(endpoint)
        input
      end
    }
  },
  warmup: 2,
  time: 10,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console
  ]
)

# Verify the pipeline worked correctly
final_count = CountingEndpoint.get_count(endpoint)
IO.puts("\nTotal messages received by endpoint: #{final_count}")

# Cleanup
Storage.stop(storage)
Storage.stop(pipeline_storage)
GenServer.stop(sender)
CountingEndpoint.stop(endpoint)
File.rm_rf!(storage_dir)
File.rm_rf!(pipeline_dir)

IO.puts("Cleanup complete.")
