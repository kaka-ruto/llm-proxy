# MIGRATION: This test needs VCR cassettes re-recorded with ask-rb.
# Tests are skipped unless RUN_OLD_MIGRATION_TESTS=1 is set.
if ENV["RUN_OLD_MIGRATION_TESTS"] != "1"
  puts "Skipping #{File.basename(__FILE__)} — set RUN_OLD_MIGRATION_TESTS=1"
  exit 0
end

require_relative "../test_helper"

describe "DeepSeek V4 Flash via OpenCode Go — Basic" do
  include VCRTestHelpers

  before do
    setup_opencode_go
  end

  it "responds to a simple prompt" do
    with_cassette("basic/simple_prompt") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      response = chat.ask "Reply with exactly: hello world"
      _(response.content).must_include "hello"
      _(response.content).must_include "world"
      _(response.output_tokens).must_be :>, 0
    end
  end

  it "streams response chunks" do
    with_cassette("basic/streaming") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chunks = []
      chat.ask("Count from 1 to 3, one per line") { |c| chunks << c.content if c.content&.length&.> 0 }
      _(chunks).wont_be :empty?
      full = chunks.join
      _(full).must_include "1"
      _(full).must_include "2"
      _(full).must_include "3"
    end
  end

  it "follows system instructions" do
    with_cassette("basic/with_system") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_instructions "Always answer in ALL CAPS. Never use lowercase."
      response = chat.ask "Say hello"
      _(response.content).must_equal response.content.upcase
    end
  end

  it "maintains conversation context" do
    with_cassette("basic/conversation") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.ask "My name is Alice."
      response = chat.ask "What is my name?"
      _(response.content).must_include "Alice"
    end
  end

  it "handles temperature parameter" do
    with_cassette("basic/with_temperature") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_temperature(0.0)
      response = chat.ask "Say hello in exactly 3 words: Hello there world"
      _(response.content.downcase).must_include "hello"
    end
  end

  it "generates structured output (JSON)" do
    with_cassette("basic/structured_output") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      response = chat.ask "Return ONLY valid JSON: {\"name\": \"test\", \"value\": 42}. Not a word before or after."
      _(response.content).must_include "name"
      _(response.content).must_include "42"
    end
  end

    it "handles long prompts" do
    with_cassette("basic/long_prompt") do
      long_text = "The quick brown fox " * 500
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      response = chat.ask "Read this text and reply with exactly: 'done'. Text: #{long_text}"
      _(response.content.downcase).must_include "done"
      # Should have used many total tokens (prompt + cached + completion)
      total = response.input_tokens + response.output_tokens + (response.cached_tokens || 0)
      _(total).must_be :>, 500
    end
  end
end
