### Added

- Telemetry events for buffer monitoring:
  - `[:loki_logger_handler, :buffer, :insert]` - emitted after buffering a log entry
  - `[:loki_logger_handler, :buffer, :remove]` - emitted after sending and removing entries
