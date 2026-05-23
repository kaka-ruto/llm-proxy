require_relative "../test_helper"

describe LLMProxy::Protocols::AnthropicMessages do
  include TestSupport

  before do
    @protocol = LLMProxy::Protocols::AnthropicMessages.new
  end

  it "has the correct endpoint" do
    _(@protocol.endpoint).must_equal "/v1/messages"
  end

  describe "#normalize" do
    it "extracts model" do
      body = { "model" => "test", "messages" => [{ "role" => "user", "content" => "hi" }] }
      _(@protocol.normalize(body)[:model]).must_equal "test"
    end

    it "normalizes developer role" do
      body = { "messages" => [{ "role" => "developer", "content" => "Be helpful" }] }
      _(@protocol.normalize(body)[:messages].first[:role]).must_equal "system"
    end

    it "extracts system prompt from string" do
      body = { "system" => "You are helpful", "messages" => [{ "role" => "user", "content" => "hi" }] }
      _(@protocol.normalize(body)[:system]).must_equal "You are helpful"
    end

    it "extracts system prompt from array" do
      body = { "system" => [{ "text" => "Be helpful" }], "messages" => [{ "role" => "user", "content" => "hi" }] }
      _(@protocol.normalize(body)[:system]).must_equal "Be helpful"
    end

    it "converts tools to correct format" do
      body = {
        "messages" => [{ "role" => "user", "content" => "hi" }],
        "tools" => [{ "name" => "get_weather", "description" => "Get weather", "input_schema" => { "type" => "object" } }]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.first[:name]).must_equal "get_weather"
      _(tools.first[:parameters]).must_equal({ "type" => "object" })
    end
  end

  describe "#start_events" do
    it "sends message_start" do
      events = @protocol.start_events(model: "test-model")
      _(events.first[:type]).must_equal "message_start"
      _(events.first.dig(:message, :model)).must_equal "test-model"
    end
  end

  describe "#chunk_events" do
    it "translates text chunks" do
      @protocol.start_events(model: "test")
      chunk = build_chunk(content: "Hello")
      events = @protocol.chunk_events(chunk, model: "test")
      _(events).wont_be :empty?
      _(events.first[:type]).must_equal "content_block_start"
    end

    it "translates thinking chunks" do
      @protocol.start_events(model: "test")
      chunk = build_chunk(thinking: "Thinking...")
      events = @protocol.chunk_events(chunk, model: "test")
      _(events).wont_be :empty?
    end
  end

  describe "#complete_events" do
    it "sends message_delta and message_stop" do
      @protocol.start_events(model: "test")
      events = @protocol.complete_events(model: "test", usage: { input: 10, output: 20 })
      types = events.map { |e| e[:type] }
      _(types).must_include "message_delta"
      _(types).must_include "message_stop"
    end
  end

  describe "#error_events" do
    it "formats errors" do
      events = @protocol.error_events("Error!")
      _(events.first[:type]).must_equal "error"
    end
  end
end
