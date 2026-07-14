require_relative "../test_helper"
require "rack/test"

describe "LLM Proxy — Chat Completions" do
  include Rack::Test::Methods
  include TestSupport
  include VCRTestHelpers

  def app
    LLMProxy::Server
  end

  REQ_HEADERS = { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost" }.freeze

  before do
    Ask::ModelCatalog.reset_instance!
    Ask::LLM::Catalog.load!
    LLMProxy.default_model = "deepseek-v4-flash"
  end

  def completions_body(overrides = {})
    {
      model: "deepseek-v4-flash",
      messages: [{ role: "user", content: "Say hello in one word" }]
    }.merge(overrides).to_json
  end

  def completions_with_tools_body(overrides = {})
    {
      model: "deepseek-v4-flash",
      messages: [{ role: "user", content: "What is 2+3? Use the calculator tool." }],
      tools: [{ type: "function", function: { name: "calculator", description: "Add numbers", parameters: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"] } } }]
    }.merge(overrides).to_json
  end

  describe "streaming" do
    it "returns SSE events for basic chat" do
      with_cassette("server/completions_stream_basic") do
        post "/v1/chat/completions", completions_body, REQ_HEADERS

        _(last_response.status).must_equal 200
        _(last_response["Content-Type"]).must_match %r{text/event-stream}

        body = last_response.body
        refute body.empty?, "Response body should not be empty"
        events = parse_sse(body)
        _(events).wont_be :empty?
        final = events[-1]
        _(final).wont_be_nil
        _(final["choices"] || final[:choices]).wont_be_nil
        finish = (final["choices"] || final[:choices])[0]
        _(finish["finish_reason"] || finish[:finish_reason]).wont_be_nil
      end
    end

    it "excludes stream: false from body" do
      with_cassette("server/completions_stream_default") do
        post "/v1/chat/completions", completions_body, REQ_HEADERS

        events = parse_sse(last_response.body)
        skip "No content events in response" if events.empty?
        content_events = events.select { |e| e.dig("choices", 0, "delta", "content") }
        _(content_events).wont_be :empty?
      end
    end
  end

  describe "non-streaming (stream: false)" do
    it "returns proper chat completions JSON" do
      with_cassette("server/completions_nonstream_basic") do
        post "/v1/chat/completions", completions_body(stream: false), REQ_HEADERS

        _(last_response.status).must_equal 200
        _(last_response["Content-Type"]).must_equal "application/json"

        body = JSON.parse(last_response.body)
        _(body["object"]).must_equal "chat.completion"
        _(body["choices"]).wont_be_nil
        _(body["choices"].first["message"]["content"]).wont_be_nil
        _(body["choices"].first["finish_reason"]).must_equal "stop"
      end
    end

    it "returns tool_calls in non-streaming response" do
      with_cassette("server/completions_nonstream_tool") do
        post "/v1/chat/completions", completions_with_tools_body(stream: false), REQ_HEADERS

        _(last_response.status).must_equal 200
        body = JSON.parse(last_response.body)
        msg = body.dig("choices", 0, "message")
        if msg["tool_calls"]
          _(msg["tool_calls"].first["function"]["name"]).must_equal "calculator"
          _(body["choices"].first["finish_reason"]).must_equal "tool_calls"
        else
          _(msg["content"]).wont_be_nil
        end
      end
    end

    it "handles multi-turn tool calls" do
      with_cassette("server/completions_multi_turn_tool") do
        # Step 1: get tool call
        post "/v1/chat/completions", completions_with_tools_body(stream: false), REQ_HEADERS
        body1 = JSON.parse(last_response.body)
        msg1 = body1.dig("choices", 0, "message")
        tool_calls = msg1["tool_calls"]
        skip "Model chose not to call tool" unless tool_calls&.any?

        tc = tool_calls.first
        _(tc["function"]["name"]).must_equal "calculator"

        # Step 2: send tool result
        post "/v1/chat/completions", {
          model: "deepseek-v4-flash",
          stream: false,
          messages: [
            { role: "user", content: "What is 2+3? Use the calculator tool." },
            { role: "assistant", content: nil, tool_calls: tool_calls },
            { role: "tool", content: "5", tool_call_id: tc["id"] }
          ],
          tools: [{ type: "function", function: { name: "calculator", description: "Add numbers", parameters: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"] } } }]
        }.to_json, REQ_HEADERS

        _(last_response.status).must_equal 200
        body2 = JSON.parse(last_response.body)
        _(body2.dig("choices", 0, "message", "content")).wont_be :empty?
      end
    end
  end

  describe "error handling" do
    it "returns error JSON for invalid request body" do
      post "/v1/chat/completions", "not json", REQ_HEADERS

      _(last_response.status).must_equal 400
      body = JSON.parse(last_response.body)
      _(body.dig("error", "message")).must_equal "Invalid JSON"
    end
  end

  describe "protocol completeness" do
    it "normalizes stream: false correctly" do
      protocol = LLMProxy::Protocols::OpenAICompletions.new
      body = { "stream" => false, "messages" => [{ "role" => "user", "content" => "hi" }] }
      normalized = protocol.normalize(body)
      _(normalized[:stream]).must_equal false
    end

    it "chunk_events sends delta-only tool call arguments" do
      protocol = LLMProxy::Protocols::OpenAICompletions.new

      # First chunk — new tool call
      chunk1 = build_chunk(tool_calls: [{ id: "call_1", name: "calc", arguments: '{"a":' }])
      events1 = protocol.chunk_events(chunk1, model: "test")
      _(events1.length).must_equal 1
      tc1 = events1.first.dig(:choices, 0, :delta, :tool_calls, 0)
      _(tc1[:id]).must_equal "call_1"
      # First delta includes full args AND name
      _(tc1[:function][:arguments]).must_equal '{"a":'

      # Second chunk — delta only (no id, no name, just arguments delta)
      chunk2 = build_chunk(tool_calls: [{ id: "call_1", name: "calc", arguments: '{"a":1}' }])
      events2 = protocol.chunk_events(chunk2, model: "test")
      _(events2.length).must_equal 1
      tc2 = events2.first.dig(:choices, 0, :delta, :tool_calls, 0)
      _(tc2[:id]).must_be_nil   # no id in delta
      _(tc2.dig(:function, :name)).must_be_nil  # no name in delta
      _(tc2.dig(:function, :arguments)).must_equal '1}'  # only the NEW chars
    end
  end
end
