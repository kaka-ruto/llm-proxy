$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
PROJECT_ROOT = File.expand_path("..", __dir__)
CONFIG_PATH = File.join(PROJECT_ROOT, "config.yml")

ENV["LLM_PROXY_CONFIG"] = CONFIG_PATH

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
require "ostruct"

# Load ask-rb ecosystem
require "ask"
require "ask/agent"
require "ask/tools/tool"
require "ask/result"
require "ask/agent/chat"
require "ask/agent/events"
require "ask-llm-providers"

# Load custom providers before llm_proxy

require_relative "../lib/llm_proxy"

# VCR setup
require "vcr"
require "webmock"

VCR.configure do |c|
  c.cassette_library_dir = File.join(PROJECT_ROOT, "test", "fixtures", "vcr_cassettes")
  c.hook_into :webmock
  c.ignore_localhost = true
  c.ignore_hosts "127.0.0.1", "localhost"

  c.filter_sensitive_data("<OPENCODE_API_KEY>") { ENV["OPENCODE_API_KEY"] || "" }
  c.filter_sensitive_data("<OPENROUTER_API_KEY>") { ENV["OPENROUTER_API_KEY"] || "" }

  c.filter_sensitive_data("<BEARER_TOKEN>") { |interaction|
    auth = interaction.request.headers["Authorization"]&.first
    auth&.start_with?("Bearer ") ? auth.sub("Bearer ", "") : nil
  }
  c.filter_sensitive_data("<BEARER_TOKEN>") { |interaction|
    auth = interaction.response.headers["Authorization"]&.first
    auth&.start_with?("Bearer ") ? auth.sub("Bearer ", "") : nil
  }

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
    # OpenCode Go provider reads OPENCODE_API_KEY from ENV
    # Ensure it's set for tests that need it
    skip "OPENCODE_API_KEY not set" unless ENV["OPENCODE_API_KEY"]
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

  # Build a mock Ask::Chunk for testing protocols
  def build_chunk(content: nil, tool_calls: nil, role: :assistant)
    tc = nil
    if tool_calls
      tc = {}
      tool_calls.each do |tc_data|
        id = tc_data[:id] || "call_#{tool_calls.index(tc_data) + 1}"
        name = tc_data[:name] || "test_tool"
        args = tc_data[:arguments] || "{}"
        tc[id] = OpenStruct.new(id: id, name: name, arguments: args)
      end
    end
    Ask::Agent::ChatChunk.new(content: content, tool_calls: tc || {})
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
