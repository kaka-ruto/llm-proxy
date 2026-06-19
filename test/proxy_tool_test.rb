# frozen_string_literal: true

require_relative "test_helper"

class ProxyToolTest < Minitest::Test
  def setup
    @server = LLMProxy::Server.new!
  end

  def test_build_dynamic_tool_returns_instance
    tool = @server.send(:build_dynamic_tool, "my_tool", "A test tool",
      { "type" => "object", "properties" => { "cmd" => { "type" => "string" } }, "required" => ["cmd"] })

    assert_kind_of Ask::Tool, tool
    assert_equal "my_tool", tool.name
    assert_equal "A test tool", tool.description
  end

  def test_build_dynamic_tool_without_params
    tool = @server.send(:build_dynamic_tool, "simple", "Simple tool", {})

    assert_kind_of Ask::Tool, tool
    assert_equal "simple", tool.name
    assert_equal({ "type" => "object" }, tool.params_schema)
  end

  def test_build_dynamic_tool_raises_tool_call_stop_on_execute
    tool = @server.send(:build_dynamic_tool, "test", "Test", {})

    assert_raises LLMProxy::ToolCallStop do
      tool.execute(foo: "bar")
    end
  end

  def test_parse_tool_args_with_json_string
    result = @server.send(:parse_tool_args, '{"cmd":"ls -la"}')
    assert_equal "ls -la", result["cmd"]
  end

  def test_parse_tool_args_with_hash
    result = @server.send(:parse_tool_args, { "cmd" => "ls" })
    assert_equal "ls", result["cmd"]
  end

  def test_parse_tool_args_with_nil
    assert_equal({}, @server.send(:parse_tool_args, nil))
  end

  def test_parse_tool_args_with_empty_string
    assert_equal({}, @server.send(:parse_tool_args, ""))
  end

  def test_parse_tool_args_with_invalid_json
    assert_equal({}, @server.send(:parse_tool_args, "not json"))
  end

  def test_build_dynamic_tool_preserves_schema
    tool = @server.send(:build_dynamic_tool, "exec_command",
      "Execute a shell command",
      {
        "type" => "object",
        "properties" => {
          "cmd" => { "type" => "string", "description" => "Command to run" },
          "timeout" => { "type" => "integer", "description" => "Timeout in ms" }
        },
        "required" => ["cmd"],
        "additionalProperties" => true
      })

    schema = tool.params_schema
    refute_nil schema, "Schema should not be nil"
    assert_equal "object", schema["type"], "Schema type should be object"
    assert schema.key?("properties"), "Schema should have properties"
    assert_equal true, schema["additionalProperties"],
      "additionalProperties should be preserved as true (not overridden to false)"
    assert schema["properties"].key?("cmd"), "Schema should have cmd property"
    assert_equal ["cmd"], schema["required"], "required should be preserved"
  end

end
