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
end
