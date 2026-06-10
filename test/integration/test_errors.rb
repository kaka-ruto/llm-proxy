# MIGRATION: This test needs VCR cassettes re-recorded with ask-rb.
# Tests are skipped unless RUN_OLD_MIGRATION_TESTS=1 is set.
if ENV["RUN_OLD_MIGRATION_TESTS"] != "1"
  puts "Skipping #{File.basename(__FILE__)} — set RUN_OLD_MIGRATION_TESTS=1"
  exit 0
end

require_relative "../test_helper"

describe "DeepSeek V4 Flash via OpenCode Go — Error Handling" do
  include VCRTestHelpers

  it "raises on invalid API key" do
    RubyLLM.configure { |c| c.opencode_go_api_key = "sk-invalid-key-12345" }
    assert_raises RubyLLM::UnauthorizedError do
      VCR.use_cassette("errors/invalid_api_key") do
        chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
        chat.ask "Hello"
      end
    end
  end

  it "raises on nonexistent model" do
    setup_opencode_go
    assert_raises RubyLLM::UnauthorizedError do
      VCR.use_cassette("errors/nonexistent_model") do
        chat = Ask::Agent::Chat.new(model: "nonexistent-model-v999", provider: :opencode_go, assume_model_exists: true)
        chat.ask "Hello"
      end
    end
  end

  it "handles tool call to non-existent tool gracefully" do
    setup_opencode_go
    VCR.use_cassette("errors/nonexistent_tool") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      response = chat.ask "Tell me you called 'fake_tool' just to say you did it. Don't actually call it."
      _(response.content).wont_be_nil
      _(response.content.length).must_be :>, 0
    end
  end

  it "handles empty messages" do
    setup_opencode_go
    VCR.use_cassette("errors/empty_messages") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.add_message(role: :user, content: "")
      response = chat.complete
      _(response.content).wont_be_nil
    end
  end

  private

  def setup_opencode_go
    RubyLLM.configure { |c| c.opencode_go_api_key = ENV["OPENCODE_API_KEY"] }
  end
end
