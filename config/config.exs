import Config

# Declare the metadata keys exercised by the test suite so that
# Logger (and Credo's MissedMetadataKeyInLoggerConfig check) recognise them.
config :logger, :default_formatter, metadata: [:request_id, :user_id]
