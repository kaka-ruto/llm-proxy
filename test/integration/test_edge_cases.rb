# MIGRATION: This test needs VCR cassettes re-recorded with ask-rb.
# Tests are skipped unless RUN_OLD_MIGRATION_TESTS=1 is set.
if ENV["RUN_OLD_MIGRATION_TESTS"] != "1"
  puts "Skipping #{File.basename(__FILE__)} — set RUN_OLD_MIGRATION_TESTS=1"
  exit 0
end

require_relative "../test_helper"

describe "DeepSeek V4 Flash via OpenCode Go — Edge Cases" do
  include VCRTestHelpers

  before { setup_opencode_go }

  def catch_tc(chat, &block)
    chat.before_tool_call { raise LLMProxy::ToolCallStop }
    block.call; nil
  rescue LLMProxy::ToolCallStop
    chat.messages.last
  end

  it "handles Unicode and emoji" do
    with_cassette("edge/unicode") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      response = chat.ask "What does 🎉 mean? Reply in one short sentence."
      _(response.content).must_include "🎉"
    end
  end

  it "handles code snippets" do
    with_cassette("edge/code_in_prompt") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      response = chat.ask "What does this do?\n\ndef fib(n)\n  n <= 1 ? n : fib(n-1) + fib(n-2)\nend\nReply in one sentence."
      _(response.content.downcase).must_include "fib"
    end
  end

  it "handles multiple languages" do
    with_cassette("edge/multi_language") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      response = chat.ask "Reply with these exact words on separate lines:\n1. Hello (English)\n2. Bonjour (French)\n3. こんにちは (Japanese)"
      _(response.content).must_include "Hello"
      _(response.content).must_include "Bonjour"
      _(response.content).must_include "こんにちは"
    end
  end

  it "handles large tool definitions (20 params)" do
    with_cassette("edge/large_tool_definitions") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)

      props = (1..20).each_with_object({}) { |i, h| h["param_#{i}"] = { type: "string" } }
      large_tool = build_dynamic_tool("many_params", "A tool with 20 params", { type: "object", properties: props, required: props.keys.first(2) })
      chat.with_tool(large_tool)

      msg = catch_tc(chat) { chat.ask "Call many_params with param_1='a' and param_2='b'." }
      _(msg).wont_be_nil
      _(msg.tool_call?).must_equal true
    end
  end

  it "handles multiple messages alternating roles" do
    with_cassette("edge/many_messages") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.add_message(role: :user, content: "My name is Bob.")
      chat.add_message(role: :assistant, content: "Hi Bob!")
      chat.add_message(role: :user, content: "I like Python.")
      chat.add_message(role: :assistant, content: "Python is great!")
      chat.add_message(role: :user, content: "What is my name and what do I like?")
      response = chat.complete
      _(response.content.downcase).must_include "bob"
      _(response.content.downcase).must_include "python"
    end
  end

  it "preserves conversation after tool failure" do
    with_cassette("edge/tool_failure_recovery") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_dynamic_tool("calculator", "Add", {
        type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"]
      }))

      msg = catch_tc(chat) { chat.ask "Add 5 and 3 using calculator." }
      if msg&.tool_call?
        tc = msg.tool_calls.values.first
        chat.add_message(role: :tool, content: "ERROR: tool crashed", tool_call_id: tc.id)
        response = chat.complete
        _(response.content.to_s.downcase).must_include("error")
      end
    end
  end

  it "handles concurrent tool calls" do
    with_cassette("edge/concurrent_tools") do
      chat = Ask::Agent::Chat.new(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_dynamic_tool("tool_a", "Tool A", { type: "object", properties: { x: { type: "string" } }, required: ["x"] }))
      chat.with_tool(build_dynamic_tool("tool_b", "Tool B", { type: "object", properties: { y: { type: "string" } }, required: ["y"] }))

      msg = catch_tc(chat) { chat.ask "Call tool_a with x='hello' AND tool_b with y='world' at the same time." }
      _(msg).wont_be_nil
      names = msg.tool_calls.values.map(&:name)
      overlap = names & %w[tool_a tool_b]
      _(overlap).wont_be :empty?
    end
  end

  private

  def setup_opencode_go
    RubyLLM.configure { |c| c.opencode_go_api_key = ENV["OPENCODE_API_KEY"] }
  end

  def build_dynamic_tool(name, description, parameters)
    schema = parameters.transform_keys(&:to_sym)
    schema[:additionalProperties] = false unless schema.key?(:additionalProperties)
    klass = Class.new(RubyLLM::Tool) do
      description(description.to_s)
      define_method(:execute) { |**| raise LLMProxy::ToolCallStop }
    end
    klass.define_method(:name) { name }
    sd = RubyLLM::Tool::SchemaDefinition.new(schema: schema)
    klass.instance_variable_set(:@params_schema_definition, sd)
    klass
  end
end
