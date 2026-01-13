# Throughput benchmark for LokiLoggerHandler
#
# Run with: mix run bench/throughput_bench.exs
#
# This benchmark measures:
# 1. Storage write throughput (CubDB vs ETS)
# 2. Full pipeline throughput (store -> batch -> send -> delete)

# Compile the counting endpoint
Code.compile_file("bench/support/counting_endpoint.ex")

alias LokiLoggerHandler.Bench.CountingEndpoint
alias LokiLoggerHandler.Storage
alias LokiLoggerHandler.Storage.{Cub, Ets}
alias LokiLoggerHandler.{Sender, Formatter}

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

# Setup for CubDB storage benchmark
cub_dir = Path.join(System.tmp_dir!(), "loki_bench_cub_#{System.unique_integer()}")
File.mkdir_p!(cub_dir)

{:ok, cub_storage} =
  Cub.start_link(
    name: :bench_cub_storage,
    data_dir: cub_dir,
    max_buffer_size: 100_000
  )

# Setup for ETS storage benchmark
{:ok, ets_storage} =
  Ets.start_link(
    name: :bench_ets_storage,
    max_buffer_size: 100_000
  )

# Setup for CubDB full pipeline benchmark
{:ok, endpoint_cub} = CountingEndpoint.start_link(port: 4998)
endpoint_cub_url = CountingEndpoint.url(endpoint_cub)

cub_pipeline_dir = Path.join(System.tmp_dir!(), "loki_bench_cub_pipeline_#{System.unique_integer()}")
File.mkdir_p!(cub_pipeline_dir)

{:ok, cub_pipeline_storage} =
  Cub.start_link(
    name: :bench_cub_pipeline_storage,
    data_dir: cub_pipeline_dir,
    max_buffer_size: 100_000
  )

{:ok, cub_sender} =
  Sender.start_link(
    name: :bench_cub_sender,
    storage: :bench_cub_pipeline_storage,
    loki_url: endpoint_cub_url,
    batch_size: batch_size,
    batch_interval_ms: 60_000,
    backoff_base_ms: 1_000,
    backoff_max_ms: 60_000
  )

# Setup for ETS full pipeline benchmark
{:ok, endpoint_ets} = CountingEndpoint.start_link(port: 4999)
endpoint_ets_url = CountingEndpoint.url(endpoint_ets)

{:ok, ets_pipeline_storage} =
  Ets.start_link(
    name: :bench_ets_pipeline_storage,
    max_buffer_size: 100_000
  )

{:ok, ets_sender} =
  Sender.start_link(
    name: :bench_ets_sender,
    storage: :bench_ets_pipeline_storage,
    loki_url: endpoint_ets_url,
    batch_size: batch_size,
    batch_interval_ms: 60_000,
    backoff_base_ms: 1_000,
    backoff_max_ms: 60_000
  )

IO.puts("\nBenchmarking with:")
IO.puts("  - batch_size: #{batch_size}")
IO.puts("  - messages_per_iteration: #{messages_per_iteration}")
IO.puts("  - CubDB endpoint: #{endpoint_cub_url}")
IO.puts("  - ETS endpoint: #{endpoint_ets_url}")
IO.puts("")

Benchee.run(
  %{
    "CubDB Storage.store (single)" => fn ->
      Storage.store(cub_storage, formatted_entry)
    end,
    "ETS Storage.store (single)" => fn ->
      Storage.store(ets_storage, formatted_entry)
    end,
    "CubDB Storage.store (#{messages_per_iteration}x)" => fn ->
      for _ <- 1..messages_per_iteration do
        Storage.store(cub_storage, formatted_entry)
      end
    end,
    "ETS Storage.store (#{messages_per_iteration}x)" => fn ->
      for _ <- 1..messages_per_iteration do
        Storage.store(ets_storage, formatted_entry)
      end
    end,
    "CubDB Full pipeline (#{messages_per_iteration}x store + flush)" => {
      fn ->
        for _ <- 1..messages_per_iteration do
          Storage.store(cub_pipeline_storage, formatted_entry)
        end

        Sender.flush(cub_sender)
      end,
      before_scenario: fn input ->
        CountingEndpoint.reset(endpoint_cub)
        input
      end
    },
    "ETS Full pipeline (#{messages_per_iteration}x store + flush)" => {
      fn ->
        for _ <- 1..messages_per_iteration do
          Storage.store(ets_pipeline_storage, formatted_entry)
        end

        Sender.flush(ets_sender)
      end,
      before_scenario: fn input ->
        CountingEndpoint.reset(endpoint_ets)
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

# Verify the pipelines worked correctly
cub_count = CountingEndpoint.get_count(endpoint_cub)
ets_count = CountingEndpoint.get_count(endpoint_ets)
IO.puts("\nTotal messages received by CubDB endpoint: #{cub_count}")
IO.puts("Total messages received by ETS endpoint: #{ets_count}")

# Cleanup
Storage.stop(cub_storage)
Storage.stop(ets_storage)
Storage.stop(cub_pipeline_storage)
Storage.stop(ets_pipeline_storage)
GenServer.stop(cub_sender)
GenServer.stop(ets_sender)
CountingEndpoint.stop(endpoint_cub)
CountingEndpoint.stop(endpoint_ets)
File.rm_rf!(cub_dir)
File.rm_rf!(cub_pipeline_dir)

IO.puts("Cleanup complete.")
