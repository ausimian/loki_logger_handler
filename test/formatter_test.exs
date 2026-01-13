defmodule LokiLoggerHandler.FormatterTest do
  use ExUnit.Case, async: true

  alias LokiLoggerHandler.Formatter

  describe "format/3" do
    test "formats a basic log event" do
      event = %{
        level: :info,
        msg: {:string, "Hello world"},
        meta: %{time: 1_000_000}
      }

      result = Formatter.format(event, %{level: :level}, [])

      assert result.level == :info
      assert result.message == "Hello world"
      assert result.timestamp == 1_000_000_000
      assert result.labels == %{"level" => "info"}
      assert result.structured_metadata == %{}
    end

    test "extracts labels from metadata" do
      event = %{
        level: :error,
        msg: {:string, "Error occurred"},
        meta: %{
          time: 1_000_000,
          application: :myapp,
          node: :node@host
        }
      }

      label_config = %{
        level: :level,
        app: {:metadata, :application},
        node: {:metadata, :node}
      }

      result = Formatter.format(event, label_config, [])

      assert result.labels == %{
               "level" => "error",
               "app" => "myapp",
               "node" => "node@host"
             }
    end

    test "extracts structured metadata" do
      event = %{
        level: :info,
        msg: {:string, "Request handled"},
        meta: %{
          time: 1_000_000,
          request_id: "abc123",
          user_id: "user456",
          other_key: "ignored"
        }
      }

      result = Formatter.format(event, %{}, [:request_id, :user_id])

      assert result.structured_metadata == %{
               "request_id" => "abc123",
               "user_id" => "user456"
             }
    end

    test "handles static label values" do
      event = %{
        level: :info,
        msg: {:string, "test"},
        meta: %{time: 1_000_000}
      }

      label_config = %{
        app: {:static, "myapp"},
        env: {:static, "production"}
      }

      result = Formatter.format(event, label_config, [])

      assert result.labels == %{
               "app" => "myapp",
               "env" => "production"
             }
    end
  end

  describe "extract_timestamp/1" do
    test "converts microseconds to nanoseconds" do
      meta = %{time: 1_234_567_890}
      assert Formatter.extract_timestamp(meta) == 1_234_567_890_000
    end

    test "uses current time when not present" do
      before = System.system_time(:nanosecond)
      result = Formatter.extract_timestamp(%{})
      after_time = System.system_time(:nanosecond)

      assert result >= before
      assert result <= after_time
    end
  end

  describe "format_message/2" do
    test "formats string message" do
      msg = {:string, "Hello world"}
      assert Formatter.format_message(msg, %{}) == "Hello world"
    end

    test "formats chardata message" do
      msg = {:string, ["Hello", ?\s, "world"]}
      assert Formatter.format_message(msg, %{}) == "Hello world"
    end

    test "formats format string with args" do
      msg = {"Value: ~p, Count: ~B", [42, 100]}
      assert Formatter.format_message(msg, %{}) == "Value: 42, Count: 100"
    end

    test "formats map report" do
      msg = {:report, %{foo: "bar", count: 42}}
      result = Formatter.format_message(msg, %{})

      # Order might vary, so check both parts are present
      assert result =~ "foo="
      assert result =~ "count="
    end

    test "formats keyword list report" do
      msg = {:report, [foo: "bar", count: 42]}
      result = Formatter.format_message(msg, %{})

      assert result =~ "foo="
      assert result =~ "count="
    end

    test "uses report_cb callback when present" do
      msg = {:report, %{custom: "data"}}

      meta = %{
        report_cb: fn report -> "Custom: #{inspect(report)}" end
      }

      result = Formatter.format_message(msg, meta)
      assert result =~ "Custom:"
    end
  end

  describe "extract_labels/2" do
    test "handles missing metadata keys gracefully" do
      event = %{
        level: :info,
        meta: %{}
      }

      label_config = %{
        level: :level,
        missing: {:metadata, :nonexistent}
      }

      result = Formatter.extract_labels(event, label_config)

      # Missing keys should be excluded
      assert result == %{"level" => "info"}
    end
  end

  describe "extract_structured_metadata/2" do
    test "ignores nil values" do
      meta = %{
        present: "value",
        missing: nil
      }

      result = Formatter.extract_structured_metadata(meta, [:present, :missing, :nonexistent])

      assert result == %{"present" => "value"}
    end

    test "converts various types to strings" do
      meta = %{
        string_val: "hello",
        atom_val: :world,
        int_val: 42,
        float_val: 3.14,
        list_val: [1, 2, 3]
      }

      result =
        Formatter.extract_structured_metadata(meta, [
          :string_val,
          :atom_val,
          :int_val,
          :float_val,
          :list_val
        ])

      assert result["string_val"] == "hello"
      assert result["atom_val"] == "world"
      assert result["int_val"] == "42"
      assert result["float_val"] == "3.14"
      assert result["list_val"] == "[1, 2, 3]"
    end
  end
end
