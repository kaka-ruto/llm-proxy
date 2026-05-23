require_relative "../test_helper"

describe LLMProxy::Protocols::OpenAICompletions do
  include TestSupport

  before do
    @protocol = LLMProxy::Protocols::OpenAICompletions.new
  end

  it "has the correct endpoint" do
    _(@protocol.endpoint).must_equal "/v1/chat/completions"
  end

  describe "#normalize" do
    it "extracts model from body" do
      body = { "model" => "test-model", "messages" => [{ "role" => "user", "content" => "hi" }] }
      normalized = @protocol.normalize(body)
      _(normalized[:model]).must_equal "test-model"
    end

    it "normalizes messages" do
      body = {
        "messages" => [
          { "role" => "developer", "content" => "Be helpful" },
          { "role" => "user", "content" => "Hello" }
        ]
      }
      normalized = @protocol.normalize(body)
      # developer should be mapped to system and extracted
      msgs = normalized[:messages]
      _(msgs.find { |m| m[:role] == "system" }).must_be_nil
    end

    it "extracts system prompt" do
      body = {
        "messages" => [
          { "role" => "system", "content" => "You are helpful" },
          { "role" => "user", "content" => "Hello" }
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:system]).must_equal "You are helpful"
    end

    it "handles multi-part content" do
      body = {
        "messages" => [
          { "role" => "user", "content" => [
            { "type" => "text", "text" => "Hello" },
            { "type" => "image_url", "image_url" => { "url" => "data:image/png;base64,abc" } }
          ]}
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:messages].first[:content]).must_equal "Hello"
    end

    it "defaults stream to true" do
      body = { "messages" => [{ "role" => "user", "content" => "hi" }] }
      normalized = @protocol.normalize(body)
      _(normalized[:stream]).must_equal true
    end

    it "honors stream: false" do
      body = { "stream" => false, "messages" => [{ "role" => "user", "content" => "hi" }] }
      normalized = @protocol.normalize(body)
      _(normalized[:stream]).must_equal false
    end
  end

  describe "#chunk_events" do
    it "translates text chunks" do
      chunk = build_chunk(content: "Hello")
      events = @protocol.chunk_events(chunk, model: "test")
      _(events).wont_be :empty?
      _(events.first[:choices].first[:delta][:content]).must_equal "Hello"
    end

    it "translates thinking chunks" do
      chunk = build_chunk(thinking: "Let me think...")
      events = @protocol.chunk_events(chunk, model: "test")
      _(events).wont_be :empty?
      _(events.first[:choices].first[:delta][:reasoning_content]).must_equal "Let me think..."
    end

    it "translates tool call chunks" do
      chunk = build_chunk(tool_calls: [{ id: "call_1", name: "get_weather", arguments: '{"city":"Paris"}' }])
      events = @protocol.chunk_events(chunk, model: "test")
      _(events).wont_be :empty?
      _(events.first[:choices].first[:delta][:tool_calls]).wont_be_nil
    end
  end

  describe "#complete_events" do
    it "returns finish signal" do
      events = @protocol.complete_events(model: "test", usage: { input: 10, output: 20 })
      _(events).wont_be :empty?
      _(events.first[:choices].first[:finish_reason]).must_equal "stop"
    end

    it "includes usage" do
      events = @protocol.complete_events(model: "test", usage: { input: 10, output: 20 })
      _(events.first[:usage]).wont_be_nil
    end
  end
end
