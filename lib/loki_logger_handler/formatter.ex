defmodule LokiLoggerHandler.Formatter do
  @moduledoc """
  Transforms Logger events into Loki-compatible format.

  Extracts labels and structured metadata based on configuration,
  and formats the remaining data as the log message line.
  """

  @type label_config :: %{atom() => :level | {:metadata, atom()}}
  @type log_event :: :logger.log_event()

  @doc """
  Formats a logger event into a storage entry.

  ## Parameters
    * `event` - The logger event map from :logger
    * `label_config` - Map of label names to extraction rules
    * `structured_metadata_keys` - List of metadata keys for structured metadata

  ## Returns
  A map with `:timestamp`, `:level`, `:message`, `:labels`, and `:structured_metadata`.
  """
  @spec format(log_event(), label_config(), [atom()]) :: map()
  def format(event, label_config, structured_metadata_keys) do
    %{level: level, msg: msg, meta: meta} = event

    timestamp = extract_timestamp(meta)
    labels = extract_labels(event, label_config)
    structured_metadata = extract_structured_metadata(meta, structured_metadata_keys)
    message = format_message(msg, meta)

    %{
      timestamp: timestamp,
      level: level,
      message: message,
      labels: labels,
      structured_metadata: structured_metadata
    }
  end

  @doc """
  Extracts the timestamp from metadata, converting to nanoseconds.

  Falls back to current system time if not present.
  """
  @spec extract_timestamp(map()) :: integer()
  def extract_timestamp(meta) do
    case Map.get(meta, :time) do
      nil ->
        System.system_time(:nanosecond)

      microseconds when is_integer(microseconds) ->
        # Logger timestamps are in microseconds
        microseconds * 1_000
    end
  end

  @doc """
  Extracts labels from a log event based on the label configuration.

  ## Label Config Format
    * `:level` - extracts the log level
    * `{:metadata, key}` - extracts a specific metadata key
    * `{:static, value}` - uses a static value

  Returns a map of label names to string values.
  """
  @spec extract_labels(log_event(), label_config()) :: %{String.t() => String.t()}
  def extract_labels(event, label_config) do
    %{level: level, meta: meta} = event

    label_config
    |> Enum.map(fn {label_name, source} ->
      value = extract_label_value(source, level, meta)
      {to_string(label_name), format_label_value(value)}
    end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp extract_label_value(:level, level, _meta), do: level
  defp extract_label_value({:metadata, key}, _level, meta), do: Map.get(meta, key)
  defp extract_label_value({:static, value}, _level, _meta), do: value
  defp extract_label_value(_other, _level, _meta), do: nil

  defp format_label_value(nil), do: nil
  defp format_label_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_label_value(value) when is_binary(value), do: value
  defp format_label_value(value), do: inspect(value)

  @doc """
  Extracts structured metadata from log metadata.

  Only includes keys that are present in the metadata and have non-nil values.
  """
  @spec extract_structured_metadata(map(), [atom()]) :: %{String.t() => String.t()}
  def extract_structured_metadata(meta, keys) do
    keys
    |> Enum.map(fn key -> {to_string(key), Map.get(meta, key)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, format_metadata_value(v)} end)
    |> Map.new()
  end

  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_metadata_value(value) when is_number(value), do: to_string(value)
  defp format_metadata_value(value), do: inspect(value)

  @doc """
  Formats the log message from the logger msg tuple.

  Handles the various message formats:
    * `{:string, chardata}` - direct string message
    * `{:report, report}` - structured report
    * `{format, args}` - format string with arguments
  """
  @spec format_message(:logger.msg_fun() | {:string, iodata()} | {:io.format(), [term()]}, map()) ::
          binary()
  def format_message({:string, chardata}, _meta) do
    IO.chardata_to_string(chardata)
  end

  def format_message({:report, report}, meta) do
    format_report(report, meta)
  end

  def format_message({format, args}, _meta) when is_list(args) do
    :io_lib.format(format, args)
    |> IO.chardata_to_string()
  end

  defp format_report(report, meta) when is_map(report) do
    case Map.get(meta, :report_cb) do
      nil ->
        report
        |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
        |> Enum.join(" ")

      callback when is_function(callback, 1) ->
        callback.(report) |> IO.chardata_to_string()

      callback when is_function(callback, 2) ->
        callback.(report, %{}) |> IO.chardata_to_string()

      {fun, extra} when is_function(fun, 2) ->
        fun.(report, extra) |> IO.chardata_to_string()
    end
  end

  defp format_report(report, _meta) when is_list(report) do
    if Keyword.keyword?(report) do
      report
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
      |> Enum.join(" ")
    else
      inspect(report)
    end
  end
end
