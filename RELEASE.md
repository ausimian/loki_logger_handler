### Added

- Telemetry events:
  - `[:loki_logger_handler, :buffer, :insert]` - emitted after buffering a log entry
  - `[:loki_logger_handler, :buffer, :remove]` - emitted after sending and removing entries
  - `[:loki_logger_handler, :format, :error]` - emitted when an event cannot be
    formatted and a fallback entry is buffered instead

### Fixed

- A single malformed log event can no longer remove the handler from `:logger`.
  Formatting now runs inside a rescue: on failure the handler buffers a best-effort
  fallback entry and emits a telemetry event rather than letting the exception
  propagate and disable the handler. The formatter also degrades gracefully on
  unexpected message, `report_cb`, and timestamp shapes instead of raising.
