# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Install dependencies
mix deps.get

# Compile (CI uses --warnings-as-errors)
mix compile --warnings-as-errors

# Run tests
mix test

# Run a single test file
mix test test/handler_test.exs

# Run a specific test by line number
mix test test/handler_test.exs:42

# Test coverage
mix coveralls

# Generate documentation
mix docs

# Run benchmarks
mix run bench/throughput_bench.exs

# Release (uses expublish, dry-run by default)
mix expublish.minor              # dry-run
mix expublish.minor --no-dry-run # actual release
```

## Architecture

This is an Erlang `:logger` handler for Grafana Loki with persistent buffering.

```
Logger → Handler → CubDB (Storage) → Sender → Loki
```

**Key modules:**

- `LokiLoggerHandler` - Public API (`attach/2`, `detach/1`, `flush/1`)
- `LokiLoggerHandler.Handler` - Implements `:logger_handler` behaviour callbacks
- `LokiLoggerHandler.Storage.Cub` - GenServer wrapping CubDB for persistent disk storage
- `LokiLoggerHandler.Storage.Ets` - GenServer wrapping ETS for in-memory storage
- `LokiLoggerHandler.Sender` - GenServer for batch sending with exponential backoff
- `LokiLoggerHandler.LokiClient` - HTTP client using Req
- `LokiLoggerHandler.Formatter` - Extracts labels and structured metadata from log events
- `LokiLoggerHandler.FakeLoki` - Plug/Bandit test server for testing without real Loki

**Storage strategies:**
- `:disk` (default) - Uses CubDB for persistent buffering, survives restarts
- `:memory` - Uses ETS for in-memory buffering, faster but lost on restart

**Supervisor structure:**
- `LokiLoggerHandler.Application` - DynamicSupervisor that manages handler instances
- `LokiLoggerHandler.CubSupervisor` - Supervises Storage.Cub + Sender for disk strategy
- `LokiLoggerHandler.EtsSupervisor` - Supervises Storage.Ets + Sender for memory strategy

Each handler instance gets its own supervisor (started under Application) which supervises both Storage and Sender. Process names use string interpolation:

```elixir
:"Elixir.LokiLoggerHandler.CubSupervisor.#{handler_id}"
:"Elixir.LokiLoggerHandler.EtsSupervisor.#{handler_id}"
:"Elixir.LokiLoggerHandler.Storage.#{handler_id}"
:"Elixir.LokiLoggerHandler.Sender.#{handler_id}"
```

**CubDB keys:** Uses `{System.monotonic_time(:nanosecond), System.unique_integer([:monotonic, :positive])}` for ordering and uniqueness.

**Loki push format:** JSON with streams containing labels, timestamps (nanoseconds), messages, and optional structured metadata (Loki 2.9+).
