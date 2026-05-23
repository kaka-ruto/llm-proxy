$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
PROJECT_ROOT = File.expand_path("..", __dir__)
CONFIG_PATH = File.join(PROJECT_ROOT, "config.yml")

ENV["LLM_PROXY_CONFIG"] = CONFIG_PATH
ENV["RUBYLLM_DEBUG"] = "false"

# Load .env for API keys in tests
dotenv = File.join(PROJECT_ROOT, ".env")
if File.exist?(dotenv)
  File.readlines(dotenv).each do |line|
    next if line.strip.empty? || line.start_with?("#")
    key, value = line.strip.split("=", 2)
    value = value&.strip&.tr("'\"", "")
    ENV[key] = value if key && value && !value.empty?
  end
end

require "bundler/setup"
require "minitest/autorun"
require "minitest/spec"
require "rack/test"
require "json"
require "yaml"
require "fileutils"

require "ruby_llm"
require "llm_proxy"

# VCR setup for recording HTTP interactions
require "vcr"
require "webmock"

VCR.configure do |c|
  c.cassette_library_dir = File.join(PROJECT_ROOT, "test", "fixtures", "vcr_cassettes")
  c.hook_into :webmock
  c.ignore_localhost = true
  c.ignore_hosts "127.0.0.1", "localhost"

  # Redact API keys in cassettes
  c.filter_sensitive_data("<OPENCODE_API_KEY>") { ENV["OPENCODE_API_KEY"] || "" }
  c.filter_sensitive_data("<OPENROUTER_API_KEY>") { ENV["OPENROUTER_API_KEY"] || "" }

  # Redact Authorization headers
  c.filter_sensitive_data("<BEARER_TOKEN>") { |interaction|
    auth = interaction.request.headers["Authorization"]&.first
    auth&.start_with?("Bearer ") ? auth.sub("Bearer ", "") : nil
  }
  c.filter_sensitive_data("<BEARER_TOKEN>") { |interaction|
    auth = interaction.response.headers["Authorization"]&.first
    auth&.start_with?("Bearer ") ? auth.sub("Bearer ", "") : nil
  }

  # Allow re-recording cassettes
  c.default_cassette_options = {
    record: ENV["VCR_RECORD"] ? :new_episodes : :once,
    match_requests_on: [:method, :uri, :body],
    allow_playback_repeats: true
  }
end

# Helper for VCR tests
module VCRTestHelpers
  def with_cassette(name, &block)
    VCR.use_cassette(name, &block)
  end

  def setup_opencode_go
    RubyLLM.configure do |c|
      c.opencode_api_key = ENV["OPENCODE_API_KEY"]
      c.opencode_go_api_key = ENV["OPENCODE_API_KEY"]
    end
  end
end

module TestSupport
  def test_config
    @test_config ||= LLMProxy::Config.load(CONFIG_PATH)
  end

  def setup_catalog
    LLMProxy.catalog = LLMProxy::ModelCatalog.new(test_config)
    LLMProxy.default_model = test_config.server[:default_model]
  end

  # Build a mock RubyLLM::Chunk for testing protocols
  def build_chunk(content: nil, thinking: nil, tool_calls: nil, role: :assistant)
    thinking_obj = thinking ? RubyLLM::Thinking.new(text: thinking) : nil
    tc = nil
    if tool_calls
      tc = {}
      tool_calls.each do |tc_data|
        id = tc_data[:id] || "call_#{tc.size + 1}"
        name = tc_data[:name] || "test_tool"
        args = tc_data[:arguments] || "{}"
        tc[id] = RubyLLM::ToolCall.new(id:, name:, arguments: args)
      end
    end
    RubyLLM::Chunk.new(
      role: role,
      model_id: "test-model",
      content: content,
      thinking: thinking_obj,
      tool_calls: tc,
      input_tokens: 10,
      output_tokens: 20
    )
  end

  # Parse SSE events from protocol output
  def parse_sse(raw)
    raw.split("\n\n").filter_map do |block|
      next if block.strip.empty?
      data = block.match(/^data: (.+)$/m)
      next unless data
      JSON.parse(data[1]) rescue nil
    end
  end
end

Minitest::Spec.register_spec_type(/Protocol/, Minitest::Spec) unless defined?(Minitest::Spec::ProtocolSpec)
