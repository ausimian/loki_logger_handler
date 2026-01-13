# LokiLoggerHandler

An Elixir Logger handler for [Grafana Loki](https://grafana.com/oss/loki/) with configurable buffering.

## Features

- **Erlang `:logger` handler** - Native integration with Elixir/Erlang logging
- **Flexible storage** - Choose disk (CubDB) for persistence or memory (ETS) for speed
- **Batch sending** - Configurable time and size thresholds for efficient delivery
- **Exponential backoff** - Graceful handling when Loki is unavailable
- **Buffer overflow protection** - Drops oldest logs when buffer is full
- **Multiple handlers** - Support different Loki endpoints with different configurations
- **Label extraction** - Flexible mapping from log metadata to Loki labels
- **Structured metadata** - Support for Loki 2.9+ non-indexed metadata
- **Test support** - Includes `FakeLoki` server for testing without a real Loki instance

## Installation

Add `loki_logger_handler` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:loki_logger_handler, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Attach a handler
LokiLoggerHandler.attach(:my_handler,
  loki_url: "http://localhost:3100",
  labels: %{
    app: {:static, "myapp"},
    env: {:metadata, :env},
    level: :level
  }
)

# Use Logger as usual
require Logger
Logger.info("User logged in", user_id: "123", request_id: "abc")

# Before shutdown, flush pending logs
LokiLoggerHandler.flush(:my_handler)
```

## Configuration

### Handler Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:loki_url` | string | *required* | Loki push API base URL |
| `:storage` | atom | `:disk` | Storage strategy: `:disk` (CubDB) or `:memory` (ETS) |
| `:labels` | map | `%{level: :level}` | Label extraction configuration |
| `:structured_metadata` | list | `[]` | Metadata keys for Loki structured metadata |
| `:data_dir` | string | `"priv/loki_buffer/<id>"` | CubDB storage directory (disk only) |
| `:batch_size` | integer | `100` | Max entries per batch |
| `:batch_interval_ms` | integer | `5000` | Max milliseconds between batches |
| `:max_buffer_size` | integer | `10000` | Max buffered entries before dropping oldest |
| `:backoff_base_ms` | integer | `1000` | Base backoff time on failure |
| `:backoff_max_ms` | integer | `60000` | Maximum backoff time |

### Label Configuration

Labels determine how logs are indexed in Loki. Configure them as a map where keys are label names and values specify extraction rules:

```elixir
labels: %{
  # Use the log level
  level: :level,

  # Extract from log metadata
  application: {:metadata, :application},
  node: {:metadata, :node},

  # Use a static value
  env: {:static, "production"},
  service: {:static, "api"}
}
```

**Important:** Labels should have low cardinality. Don't use high-cardinality values like user IDs or request IDs as labels.

### Structured Metadata (Loki 2.9+)

Structured metadata allows attaching key-value pairs that aren't indexed but can still be queried. Use this for high-cardinality data:

```elixir
LokiLoggerHandler.attach(:my_handler,
  loki_url: "http://localhost:3100",
  labels: %{level: :level},
  structured_metadata: [:request_id, :user_id, :trace_id, :span_id]
)

# These will be attached as structured metadata, not labels
Logger.info("Request handled", request_id: "req-123", user_id: "user-456")
```

## Multiple Handlers

You can attach multiple handlers with different configurations:

```elixir
# Application logs to one Loki instance
LokiLoggerHandler.attach(:app_logs,
  loki_url: "http://loki-app:3100",
  labels: %{app: {:static, "myapp"}, level: :level}
)

# Audit logs to another Loki instance
LokiLoggerHandler.attach(:audit_logs,
  loki_url: "http://loki-audit:3100",
  labels: %{type: {:static, "audit"}, level: :level}
)
```

## API Reference

### Attaching and Detaching

```elixir
# Attach a handler
:ok = LokiLoggerHandler.attach(:my_handler, opts)

# Detach a handler
:ok = LokiLoggerHandler.detach(:my_handler)

# List all attached handlers
[:my_handler] = LokiLoggerHandler.list_handlers()
```

### Flushing Logs

```elixir
# Force immediate send of pending logs
:ok = LokiLoggerHandler.flush(:my_handler)
```

### Configuration Management

```elixir
# Get current configuration
{:ok, config} = LokiLoggerHandler.get_config(:my_handler)

# Update configuration
:ok = LokiLoggerHandler.update_config(:my_handler, batch_size: 200)
```

## Testing

The library includes `LokiLoggerHandler.FakeLoki`, a Plug-based fake Loki server for testing:

```elixir
defmodule MyApp.LoggingTest do
  use ExUnit.Case

  alias LokiLoggerHandler.FakeLoki

  setup do
    # Start with an ephemeral port (OS-assigned)
    {:ok, fake} = FakeLoki.start_link()

    LokiLoggerHandler.attach(:test_handler,
      loki_url: FakeLoki.url(fake),
      batch_interval_ms: 100
    )

    on_exit(fn ->
      LokiLoggerHandler.detach(:test_handler)
      FakeLoki.stop(fake)
    end)

    {:ok, fake: fake}
  end

  test "logs are sent to Loki", %{fake: fake} do
    require Logger
    Logger.info("Test message", request_id: "123")

    # Wait for batch to be sent
    Process.sleep(200)

    # Assert on received logs
    entries = FakeLoki.get_entries(fake)
    assert length(entries) >= 1

    # Get flattened log values
    values = FakeLoki.get_log_values(fake)
    assert Enum.any?(values, fn {_ts, msg, _meta} ->
      String.contains?(msg, "Test message")
    end)
  end
end
```

### FakeLoki API

```elixir
# Start the fake server (uses OS-assigned ephemeral port)
{:ok, fake} = FakeLoki.start_link()

# Or specify a port explicitly
{:ok, fake} = FakeLoki.start_link(port: 4100)

# Get the URL for handler configuration
url = FakeLoki.url(fake)  # "http://localhost:<port>"

# Get all received push requests
entries = FakeLoki.get_entries(fake)

# Get flattened log values as {timestamp, message, metadata} tuples
values = FakeLoki.get_log_values(fake)

# Clear received entries
FakeLoki.clear(fake)

# Stop the server
FakeLoki.stop(fake)
```

## Architecture

```
┌──────────────┐     ┌─────────────┐     ┌────────────┐     ┌──────────┐
│   Logger     │────▶│   Handler   │────▶│  Storage   │────▶│  Sender  │────▶ Loki
│  (events)    │     │  (format)   │     │ (buffer)   │     │ (batch)  │
└──────────────┘     └─────────────┘     └────────────┘     └──────────┘
```

1. **Handler** - Receives log events from Erlang's `:logger`, formats them, and stores in the buffer
2. **Storage** - Pluggable buffer with monotonic keys for ordering:
   - `:disk` - CubDB-backed persistent storage (survives restarts)
   - `:memory` - ETS-backed in-memory storage (faster, no persistence)
3. **Sender** - GenServer that periodically reads batches and sends to Loki via HTTP
4. **LokiClient** - Formats and sends log batches using the Loki push API (JSON format)

## Failure Handling

When Loki is unavailable:

1. Logs continue to be buffered in storage
2. Sender applies exponential backoff (1s → 2s → 4s → ... up to max)
3. When buffer reaches `max_buffer_size`, oldest logs are dropped
4. On successful send, backoff resets to normal interval

**Note:** With `:disk` storage, buffered logs survive application restarts. With `:memory` storage, logs are lost on restart but throughput is higher.

## License

MIT License. See [LICENSE](LICENSE) for details.
