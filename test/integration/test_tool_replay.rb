require_relative "../test_helper"

describe "DeepSeek V4 Flash via OpenCode Go — Tool Replay" do
  include VCRTestHelpers

  before { setup_opencode_go }

  def catch_tc(chat, &block)
    chat.before_tool_call { raise LLMProxy::ToolCallStop }
    block.call; nil
  rescue LLMProxy::ToolCallStop
    chat.messages.last
  end

  it "completes tool call round-trip" do
    with_cassette("tool_replay/single_round") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_calc_tool)

      msg = catch_tc(chat) { chat.ask "Add 5 and 7 using the calculator tool." }
      _(msg.tool_call?).must_equal true

      tc = msg.tool_calls.values.first
      result = (tc.arguments["a"].to_i + tc.arguments["b"].to_i).to_s
      chat.add_message(role: :tool, content: result, tool_call_id: tc.id)

      response = chat.complete
      _(response.content.to_s).must_include "12"
    end
  end

  it "preserves tool_call_id" do
    with_cassette("tool_replay/tool_call_id") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_exec_tool)

      msg = catch_tc(chat) { chat.ask "Run exec_command with cmd='echo hello'" }
      _(msg).wont_be_nil
      tc = msg.tool_calls.values.first
      _(tc.id).must_match(/^call_/)
    end
  end

  it "handles tool calls from pre-built history" do
    with_cassette("tool_replay/from_history") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_calc_tool)

      chat.add_message(role: :user, content: "Add 100 and 200 using calculator. Result: 300")
      chat.add_message(role: :user, content: "Now add 50 and 25 using the same tool.")

      msg = catch_tc(chat) { chat.complete }
      _(msg.tool_call?).must_equal true
      _(msg.tool_calls.values.first.name).must_equal "calculator"
    end
  end

  private

  def build_calc_tool
    build_dynamic_tool("calculator", "Add two numbers", {
      type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"]
    })
  end

  def build_exec_tool
    build_dynamic_tool("exec_command", "Execute a shell command", {
      type: "object", properties: { cmd: { type: "string" } }, required: ["cmd"]
    })
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
