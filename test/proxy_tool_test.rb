# frozen_string_literal: true

require_relative "test_helper"
require "mocha/minitest"

class ProxyToolTest < Minitest::Test
  def setup
    require "logger"
    @server = LLMProxy::Server.new!
    @server.instance_variable_set(:@log, Logger.new(File::NULL))
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

  def test_execute_web_search_tools_returns_false_when_no_tool_calls
    response = Ask::Agent::ResponseMessage.new(content: "Hello", tool_calls: {}, thinking: nil)
    refute @server.send(:execute_web_search_tools, nil, response, 0)
  end

  def test_execute_web_search_tools_returns_false_when_no_web_search_calls
    tool_calls = {
      "call_1" => OpenStruct.new(id: "call_1", name: "other_tool", arguments: { "x" => "1" })
    }
    response = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tool_calls, thinking: nil)
    refute @server.send(:execute_web_search_tools, nil, response, 0)
  end

  def test_execute_web_search_tools_executes_and_adds_result
    tool_calls = {
      "call_1" => OpenStruct.new(id: "call_1", name: "web_search", arguments: { "query" => "Ruby language" })
    }
    response = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tool_calls, thinking: nil)

    Ask::Tools::WebSearch.any_instance.stubs(:execute).returns("1. Ruby — A Programmer's Best Friend\nhttps://www.ruby-lang.org")

    add_calls = []
    chat = Object.new
    chat.define_singleton_method(:add_message) { |**args| add_calls << args }

    result = @server.send(:execute_web_search_tools, chat, response, 0)
    assert result
    assert_equal 1, add_calls.length
    assert_equal :tool, add_calls[0][:role]
    assert_match(/\d+\./, add_calls[0][:content])
    assert_equal "call_1", add_calls[0][:tool_call_id]
  end

  def test_execute_web_search_tools_handles_multiple_calls
    tool_calls = {
      "call_1" => OpenStruct.new(id: "call_1", name: "web_search", arguments: { "query" => "Ruby" }),
      "call_2" => OpenStruct.new(id: "call_2", name: "web_search", arguments: { "query" => "Python" })
    }
    response = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tool_calls, thinking: nil)

    Ask::Tools::WebSearch.any_instance.stubs(:execute).returns("1. Result")

    add_calls = []
    chat = Object.new
    chat.define_singleton_method(:add_message) { |**args| add_calls << args }

    result = @server.send(:execute_web_search_tools, chat, response, 0)
    assert result
    assert_equal 2, add_calls.length
  end

  def test_execute_web_search_tools_with_string_arguments
    tool_calls = {
      "call_1" => OpenStruct.new(id: "call_1", name: "web_search", arguments: '{"query":"Ruby language"}')
    }
    response = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tool_calls, thinking: nil)

    Ask::Tools::WebSearch.any_instance.stubs(:execute).returns("1. Ruby language resources\nhttps://www.ruby-lang.org")

    add_calls = []
    chat = Object.new
    chat.define_singleton_method(:add_message) { |**args| add_calls << args }

    result = @server.send(:execute_web_search_tools, chat, response, 0)
    assert result
    assert_equal 1, add_calls.length
    assert_equal "call_1", add_calls[0][:tool_call_id]
    assert_match(/Ruby|ruby/, add_calls[0][:content])
  end

  def test_build_stream_complete_event_for_openai_completions
    msg = Ask::Agent::ResponseMessage.new(content: "Hello!", tool_calls: {}, thinking: nil)
    protocol = LLMProxy::Protocols::OpenAICompletions.new
    events = @server.send(:build_stream_complete_event, protocol, OpenStruct.new(id: "test-model"), msg, { input: 10, output: 20 })
    assert_equal 1, events.length
    assert_equal "stop", events[0][:choices][0][:finish_reason]
    assert events[0][:usage]
  end

  def test_build_stream_complete_event_for_openai_responses
    msg = Ask::Agent::ResponseMessage.new(content: "Hello!", tool_calls: {}, thinking: nil)
    protocol = LLMProxy::Protocols::OpenAIResponses.new
    events = @server.send(:build_stream_complete_event, protocol, OpenStruct.new(id: "test-model"), msg, nil)
    assert_equal 1, events.length
    assert_equal "response.completed", events[0][:type]
    assert_equal 1, events[0][:response][:output].length
    assert_equal "message", events[0][:response][:output][0][:type]
  end

  def test_build_stream_complete_event_for_anthropic
    msg = Ask::Agent::ResponseMessage.new(content: "Hello!", tool_calls: {}, thinking: nil)
    protocol = LLMProxy::Protocols::AnthropicMessages.new
    events = @server.send(:build_stream_complete_event, protocol, OpenStruct.new(id: "test-model"), msg, nil)
    assert_equal 2, events.length
    assert_equal "message_delta", events[0][:type]
    assert_equal "message_stop", events[1][:type]
  end

  def test_build_stream_complete_event_includes_tool_calls
    tool_calls = {
      "call_1" => OpenStruct.new(id: "call_1", name: "calculator", arguments: { "a" => 1, "b" => 2 })
    }
    msg = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tool_calls, thinking: nil)
    protocol = LLMProxy::Protocols::OpenAICompletions.new
    events = @server.send(:build_stream_complete_event, protocol, OpenStruct.new(id: "test-model"), msg, nil)
    assert_equal "tool_calls", events[0][:choices][0][:finish_reason]
  end
end
