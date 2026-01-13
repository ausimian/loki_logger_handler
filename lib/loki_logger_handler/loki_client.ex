defmodule LokiLoggerHandler.LokiClient do
  # HTTP client for Loki push API.
  #
  # Formats log entries and sends them to Loki using the JSON push format.
  # Supports both labels and structured metadata (Loki 2.9+).

  @moduledoc false

  @push_path "/loki/api/v1/push"

  @type entry :: %{
          timestamp: integer(),
          level: atom(),
          message: binary(),
          labels: map(),
          structured_metadata: map()
        }

  # Pushes a batch of log entries to Loki.
  #
  # Parameters:
  #   * loki_url - The base URL of the Loki instance (e.g., "http://localhost:3100")
  #   * entries - List of log entries to push
  #
  # Returns :ok on success or {:error, reason} on failure.
  @doc false
  @spec push(String.t(), [entry()]) :: :ok | {:error, term()}
  def push(_loki_url, []), do: :ok

  def push(loki_url, entries) when is_list(entries) do
    url = loki_url <> @push_path
    body = build_push_body(entries)

    case Req.post(url, json: body) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  # Builds the Loki push API request body.
  #
  # Groups entries by their labels (since Loki requires one stream per label set),
  # then formats according to the Loki push API JSON format.
  @doc false
  @spec build_push_body([entry()]) :: map()
  def build_push_body(entries) do
    streams =
      entries
      |> Enum.group_by(& &1.labels)
      |> Enum.map(fn {labels, group_entries} ->
        values =
          group_entries
          |> Enum.sort_by(& &1.timestamp)
          |> Enum.map(&format_value/1)

        %{
          "stream" => labels,
          "values" => values
        }
      end)

    %{"streams" => streams}
  end

  # Formats a single log entry as a Loki value tuple.
  # Format: [timestamp_ns_string, message, structured_metadata]
  defp format_value(entry) do
    timestamp_str = Integer.to_string(entry.timestamp)

    if map_size(entry.structured_metadata) > 0 do
      [timestamp_str, entry.message, entry.structured_metadata]
    else
      [timestamp_str, entry.message]
    end
  end
end
