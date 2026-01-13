### Added

- Erlang `:logger` handler implementation for Grafana Loki
- Persistent log buffering via CubDB (survives application restarts)
- Configurable label extraction from log metadata
- Structured metadata support (Loki 2.9+)
- Dual threshold batching (time interval and batch size)
- Exponential backoff on Loki unavailability
- Buffer overflow protection (drops oldest logs when full)
- Multiple handler support for different Loki endpoints
- `LokiLoggerHandler.FakeLoki` test server for testing without real Loki
- Flush API for graceful shutdown
- Runtime configuration updates
