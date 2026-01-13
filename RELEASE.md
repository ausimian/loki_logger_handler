### Added

- Erlang `:logger` handler implementation for Grafana Loki
- Configurable storage strategy:
  - `:disk` (default) - CubDB-backed persistent storage that survives restarts
  - `:memory` - ETS-backed in-memory storage for higher throughput
- Configurable label extraction from log metadata
- Structured metadata support (Loki 2.9+)
- Dual threshold batching (time interval and batch size)
- Exponential backoff on Loki unavailability
- Buffer overflow protection (drops oldest logs when full)
- Multiple handler support for different Loki endpoints
- `LokiLoggerHandler.FakeLoki` test server with ephemeral port support
- Flush API for graceful shutdown
- Runtime configuration updates
