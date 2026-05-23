$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
PROJECT_ROOT = File.expand_path("..", __dir__)
CONFIG_PATH = File.join(PROJECT_ROOT, "config.yml")

ENV["LLM_PROXY_CONFIG"] = CONFIG_PATH
ENV["RUBYLLM_DEBUG"] = "false"

require "bundler/setup"
require "minitest/autorun"
require "minitest/spec"
require "rack/test"
require "json"
require "yaml"
require "fileutils"

require "ruby_llm"
require "llm_proxy"

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
