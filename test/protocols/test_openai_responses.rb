require_relative "../test_helper"

describe LLMProxy::Protocols::OpenAIResponses do
  include TestSupport

  before do
    @protocol = LLMProxy::Protocols::OpenAIResponses.new
  end

  it "has the correct endpoint" do
    _(@protocol.endpoint).must_equal "/v1/responses"
  end

  describe "#normalize" do
    it "extracts model" do
      body = { "model" => "test", "input" => [] }
      _(@protocol.normalize(body)[:model]).must_equal "test"
    end

    it "maps developer role to system" do
      body = {
        "input" => [
          { "type" => "message", "role" => "developer", "content" => [{ "type" => "input_text", "text" => "Be helpful" }] }
        ]
      }
      normalized = @protocol.normalize(body)
      msg = normalized[:messages].first
      _(msg[:role]).must_equal "system"
    end

    it "extracts messages from input" do
      body = {
        "input" => [
          { "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => "Hello" }] }
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:messages].first[:content]).must_equal "Hello"
    end

    it "converts function_call items" do
      body = {
        "input" => [
          { "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => "Weather?" }] },
          { "type" => "function_call", "call_id" => "call_1", "name" => "get_weather", "arguments" => "{\"city\":\"Paris\"}" },
          { "type" => "function_call_output", "call_id" => "call_1", "output" => "Sunny" }
        ]
      }
      normalized = @protocol.normalize(body)
      msgs = normalized[:messages]
      _(msgs.size).must_equal 3
      _(msgs[1][:tool_calls]).wont_be_nil
      _(msgs[2][:tool_call_id]).must_equal "call_1"
    end

    it "handles instructions as system prompt" do
      body = { "input" => [], "instructions" => "You are helpful" }
      _(@protocol.normalize(body)[:system]).must_equal "You are helpful"
    end

    it "extracts tools" do
      body = {
        "input" => [],
        "tools" => [
          {
            "type" => "function",
            "function" => {
              "name" => "exec_command",
              "description" => "Run a command",
              "parameters" => { "type" => "object", "properties" => { "cmd" => { "type" => "string" } } }
            }
          }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:name]).must_equal "exec_command"
    end

    it "filters custom/grammar tools" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "custom", "name" => "apply_patch", "format" => { "type" => "grammar" } },
          { "type" => "function", "name" => "exec_command", "function" => { "name" => "exec_command", "parameters" => { "type" => "object" } } }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:name]).must_equal "exec_command"
    end

    it "filters tools without parameters" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "function", "name" => "broken_tool" }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools).must_be :empty?
    end
  end

  describe "#start_events" do
    it "creates response.created event" do
      events = @protocol.start_events(model: "test-model")
      _(events.size).must_equal 1
      _(events.first[:type]).must_equal "response.created"
      _(events.first.dig(:response, :model)).must_equal "test-model"
      _(events.first.dig(:response, :status)).must_equal "in_progress"
    end
  end

  describe "#chunk_events" do
    it "translates text chunks" do
      @protocol.start_events(model: "test")
      chunk = build_chunk(content: "Hello")
      events = @protocol.chunk_events(chunk, model: "test")
      _(events).wont_be :empty?
      _(events.first[:type]).must_equal "response.output_item.added"
    end

    it "translates reasoning chunks" do
      @protocol.start_events(model: "test")
      chunk = build_chunk(thinking: "Thinking...")
      events = @protocol.chunk_events(chunk, model: "test")
      _(events).wont_be :empty?
      _(events.first[:type]).must_equal "response.output_item.added"
    end

    it "translates tool call chunks with full arguments" do
      @protocol.start_events(model: "test")
      chunk = build_chunk(tool_calls: [{ id: "call_1", name: "exec_command", arguments: '{"cmd":"ls"}' }])
      events = @protocol.chunk_events(chunk, model: "test")
      _(events).wont_be :empty?
      # Arguments can be in output_item.added OR in a function_call_arguments.delta
      added = events.find { |e| e[:type] == "response.output_item.added" }
      delta = events.find { |e| e[:type] == "response.function_call_arguments.delta" }
      _(added || delta).wont_be_nil
      if added&.dig(:item, :arguments)&.length&.>(0)
        _(added.dig(:item, :arguments)).must_include "ls"
      else
        _(delta).wont_be_nil
        _(delta[:delta]).must_include "ls"
      end
    end

    it "handles tool calls with empty initial arguments" do
      @protocol.start_events(model: "test")
      # First chunk: tool call with empty arguments
      chunk1 = build_chunk(tool_calls: [{ id: "call_1", name: "exec_command", arguments: "" }])
      events1 = @protocol.chunk_events(chunk1, model: "test")
      _(events1.first[:type]).must_equal "response.output_item.added"

      # Second chunk: arguments arrive
      chunk2 = build_chunk(tool_calls: [{ id: "call_1", name: "exec_command", arguments: '{"cmd":"ls"}' }])
      events2 = @protocol.chunk_events(chunk2, model: "test")
      delta = events2.find { |e| e[:type] == "response.function_call_arguments.delta" }
      _(delta).wont_be_nil
      _(delta[:delta]).must_equal '{"cmd":"ls"}'
    end
  end

  describe "#complete_events" do
    it "sends response.completed" do
      @protocol.start_events(model: "test")
      events = @protocol.complete_events(model: "test", usage: { input: 10, output: 20 })
      completed = events.find { |e| e[:type] == "response.completed" }
      _(completed).wont_be_nil
      _(completed.dig(:response, :status)).must_equal "completed"
    end

    it "includes usage information" do
      @protocol.start_events(model: "test")
      events = @protocol.complete_events(model: "test", usage: { input: 10, output: 20 })
      completed = events.find { |e| e[:type] == "response.completed" }
      usage = completed.dig(:response, :usage)
      _(usage[:total_tokens]).must_equal 30
    end

    it "does not send empty arguments for tool calls" do
      @protocol.start_events(model: "test")
      # Simulate a tool call with empty arguments
      chunk = build_chunk(tool_calls: [{ id: "call_1", name: "exec_command", arguments: "" }])
      @protocol.chunk_events(chunk, model: "test")

      events = @protocol.complete_events(model: "test")
      done_event = events.find { |e| e[:type] == "response.function_call_arguments.done" }
      _(done_event).wont_be_nil
      _(done_event[:arguments]).must_equal "{}"  # Not empty string
    end
  end

  describe "#error_events" do
    it "formats error events" do
      events = @protocol.error_events("Something went wrong")
      _(events.first[:type]).must_equal "error"
      _(events.first.dig(:error, :message)).must_equal "Something went wrong"
    end
  end

  describe "#chunk_events with parallel tool calls" do
    it "routes multiple parallel tool calls by id, not reverse-find" do
      protocol = LLMProxy::Protocols::OpenAIResponses.new
      protocol.send(:start_events, model: "test")

      tc1 = Ask::Agent::ToolCallInfo.new(id: "call_1", name: "read_file", arguments: "")
      c1 = Ask::Agent::ChatChunk.new(content: nil, tool_calls: { "call_1" => tc1 }, thinking: nil)
      e1 = protocol.chunk_events(c1, model: "test")
      added1 = e1.select { |e| e[:type] == "response.output_item.added" }
      _(added1.length).must_equal 1
      _(added1.first[:item][:call_id]).must_equal "call_1"

      tc2 = Ask::Agent::ToolCallInfo.new(id: "call_2", name: "search_files", arguments: "")
      c2 = Ask::Agent::ChatChunk.new(content: nil, tool_calls: { "call_2" => tc2 }, thinking: nil)
      e2 = protocol.chunk_events(c2, model: "test")
      added2 = e2.select { |e| e[:type] == "response.output_item.added" }
      _(added2.length).must_equal 1
      _(added2.first[:item][:call_id]).must_equal "call_2"

      tc = protocol.instance_variable_get(:@tool_calls)
      _(tc.keys).must_include "call_1"
      _(tc.keys).must_include "call_2"
      _(tc.length).must_equal 2
    end

    it "accumulates arguments for parallel calls without mixing" do
      protocol = LLMProxy::Protocols::OpenAIResponses.new
      protocol.send(:start_events, model: "test")

      tc1 = Ask::Agent::ToolCallInfo.new(id: "call_1", name: "tool_a", arguments: "")
      protocol.chunk_events(
        Ask::Agent::ChatChunk.new(content: nil, tool_calls: { "call_1" => tc1 }, thinking: nil),
        model: "test"
      )

      tc2 = Ask::Agent::ToolCallInfo.new(id: "call_2", name: "tool_b", arguments: "")
      protocol.chunk_events(
        Ask::Agent::ChatChunk.new(content: nil, tool_calls: { "call_2" => tc2 }, thinking: nil),
        model: "test"
      )

      tc1a = Ask::Agent::ToolCallInfo.new(id: "call_1", name: "tool_a", arguments: %q({"key": "val"}))
      e3 = protocol.chunk_events(
        Ask::Agent::ChatChunk.new(content: nil, tool_calls: { "call_1" => tc1a }, thinking: nil),
        model: "test"
      )

      tc2a = Ask::Agent::ToolCallInfo.new(id: "call_2", name: "tool_b", arguments: %q({"query": "foo"}))
      e4 = protocol.chunk_events(
        Ask::Agent::ChatChunk.new(content: nil, tool_calls: { "call_2" => tc2a }, thinking: nil),
        model: "test"
      )

      t1 = protocol.instance_variable_get(:@tool_calls)["call_1"]
      _(t1[:arguments]).must_equal %q({"key": "val"})

      t2 = protocol.instance_variable_get(:@tool_calls)["call_2"]
      _(t2[:arguments]).must_equal %q({"query": "foo"})

      ds1 = e3.select { |e| e[:type] == "response.function_call_arguments.delta" }
      _(ds1.length).must_equal 1
      _(ds1.first[:item_id]).must_equal "call_1"

      ds2 = e4.select { |e| e[:type] == "response.function_call_arguments.delta" }
      _(ds2.length).must_equal 1
      _(ds2.first[:item_id]).must_equal "call_2"
    end
  end
end
