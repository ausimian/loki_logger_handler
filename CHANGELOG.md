# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

## 0.2.0 - 2026-01-22

### Added

- Telemetry events for buffer monitoring:
  - `[:loki_logger_handler, :buffer, :insert]` - emitted after buffering a log entry
  - `[:loki_logger_handler, :buffer, :remove]` - emitted after sending and removing entries


## 0.1.1 - 2026-01-13

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


