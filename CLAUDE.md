# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

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

# Release (uses expublish)
mix expublish.minor  # or .major, .patch
```

## Architecture

This is an Erlang `:logger` handler for Grafana Loki with persistent buffering.

```
Logger → Handler → CubDB (Storage) → Sender → Loki
```

**Key modules:**

- `LokiLoggerHandler` - Public API (`attach/2`, `detach/1`, `flush/1`)
- `LokiLoggerHandler.Handler` - Implements `:logger_handler` behaviour callbacks
- `LokiLoggerHandler.Storage` - GenServer wrapping CubDB for persistent buffering
- `LokiLoggerHandler.Sender` - GenServer for batch sending with exponential backoff
- `LokiLoggerHandler.LokiClient` - HTTP client using Req
- `LokiLoggerHandler.Formatter` - Extracts labels and structured metadata from log events
- `LokiLoggerHandler.FakeLoki` - Plug/Bandit test server for testing without real Loki

**Supervisor structure:**
- `LokiLoggerHandler.Application` - DynamicSupervisor that manages handler instances
- `LokiLoggerHandler.PairSupervisor` - Regular Supervisor with `auto_shutdown: :all_significant`, supervises Storage and Sender as a pair

Each handler instance gets its own PairSupervisor (started under Application) which supervises both Storage and Sender. Process names use string interpolation to avoid module aliasing issues:

```elixir
:"Elixir.LokiLoggerHandler.PairSupervisor.#{handler_id}"
:"Elixir.LokiLoggerHandler.Storage.#{handler_id}"
:"Elixir.LokiLoggerHandler.Sender.#{handler_id}"
```

**CubDB keys:** Uses `{System.monotonic_time(:nanosecond), System.unique_integer([:monotonic, :positive])}` for ordering and uniqueness.

**Loki push format:** JSON with streams containing labels, timestamps (nanoseconds), messages, and optional structured metadata (Loki 2.9+).
