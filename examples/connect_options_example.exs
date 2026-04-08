#!/usr/bin/env elixir

# Example: Using connect_options to customize HTTP connection behavior
#
# This example demonstrates how to configure the HTTP client used by
# LokiLoggerHandler to send logs to Loki. This is useful for:
# - Configuring timeouts
# - SSL/TLS settings
# - Proxy configuration
# - Connection pooling
# - HTTP/2 settings

Mix.install([
  {:loki_logger_handler, path: Path.expand("..", __DIR__)}
])

require Logger

# Example 1: Basic timeout configuration
IO.puts("\n=== Example 1: Custom Timeouts ===\n")

LokiLoggerHandler.attach(:timeout_example,
  loki_url: "http://localhost:3100",
  labels: %{example: {:static, "timeouts"}},
  batch_interval_ms: 2_000,
  connect_options: [
    # Request timeout (default is typically 5_000ms)
    timeout: 30_000,
    # Connection pool checkout timeout
    pool_timeout: 5_000
  ]
)

Logger.info("This log will be sent with a 30-second timeout")

# Example 2: SSL/TLS configuration for HTTPS endpoints
IO.puts("\n=== Example 2: SSL/TLS Configuration ===\n")

LokiLoggerHandler.attach(:ssl_example,
  loki_url: "https://secure-loki.example.com:3100",
  labels: %{example: {:static, "ssl"}},
  batch_interval_ms: 2_000,
  connect_options: [
    timeout: 15_000,
    transport_opts: [
      # Verify peer certificates
      verify: :verify_peer,
      # Path to CA certificate file
      cacertfile: "/etc/ssl/certs/ca-bundle.crt",
      # Or use system CA certificates
      # cacerts: :public_key.cacerts_get(),
      # Verify hostname matches certificate
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  ]
)

Logger.info("This log will be sent over verified HTTPS")

# Example 3: HTTP/2 configuration
IO.puts("\n=== Example 3: HTTP/2 Configuration ===\n")

LokiLoggerHandler.attach(:http2_example,
  loki_url: "https://loki.example.com:3100",
  labels: %{example: {:static, "http2"}},
  batch_interval_ms: 2_000,
  connect_options: [
    # Force HTTP/2 protocol
    protocols: [:http2],
    timeout: 15_000
  ]
)

Logger.info("This log will be sent using HTTP/2")

# Example 4: Proxy configuration
IO.puts("\n=== Example 4: Proxy Configuration ===\n")

LokiLoggerHandler.attach(:proxy_example,
  loki_url: "http://loki.example.com:3100",
  labels: %{example: {:static, "proxy"}},
  batch_interval_ms: 2_000,
  connect_options: [
    # Configure HTTP proxy (note: this requires Req 0.4.0+)
    proxy: {:http, "proxy.example.com", 8080, []},
    # Or HTTPS proxy with authentication:
    # proxy: {:https, "proxy.example.com", 8443, [
    #   proxy_headers: [{"proxy-authorization", "Basic base64encodedcreds"}]
    # ]},
    timeout: 15_000
  ]
)

Logger.info("This log will be sent through a proxy")

# Example 5: Self-signed certificates (development/testing)
IO.puts("\n=== Example 5: Self-Signed Certificates ===\n")

LokiLoggerHandler.attach(:self_signed_example,
  loki_url: "https://localhost:3100",
  labels: %{example: {:static, "self-signed"}},
  batch_interval_ms: 2_000,
  connect_options: [
    timeout: 15_000,
    transport_opts: [
      # WARNING: Only use in development/testing!
      # This disables certificate verification
      verify: :verify_none
    ]
  ]
)

Logger.warning("Using verify_none - only for development!")
Logger.info("This log accepts self-signed certificates")

# Example 6: Connection pooling
IO.puts("\n=== Example 6: Connection Pooling ===\n")

LokiLoggerHandler.attach(:pool_example,
  loki_url: "http://localhost:3100",
  labels: %{example: {:static, "pooling"}},
  batch_interval_ms: 2_000,
  connect_options: [
    timeout: 10_000,
    pool_timeout: 5_000,
    # Maximum number of connections in the pool
    # (This is handled by Req's underlying HTTP client)
    receive_timeout: 10_000
  ]
)

Logger.info("This log uses connection pooling")

# Give time for logs to be sent
IO.puts("\n=== Waiting for logs to be sent... ===\n")
Process.sleep(3_000)

# Flush all handlers
IO.puts("\n=== Flushing all handlers ===\n")

for handler_id <- LokiLoggerHandler.list_handlers() do
  IO.puts("Flushing #{handler_id}...")
  LokiLoggerHandler.flush(handler_id)
end

IO.puts("\n=== Done! ===\n")

# Clean up
for handler_id <- LokiLoggerHandler.list_handlers() do
  LokiLoggerHandler.detach(handler_id)
end
