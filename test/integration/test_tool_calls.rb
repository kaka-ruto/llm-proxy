require_relative "../test_helper"

describe "DeepSeek V4 Flash via OpenCode Go — Tool Calls" do
  include VCRTestHelpers

  before do
    setup_opencode_go
  end

  def catch_tool_call(chat, &block)
    chat.before_tool_call { raise LLMProxy::ToolCallStop }
    block.call
    nil
  rescue LLMProxy::ToolCallStop
    chat.messages.last
  end

  it "calls a simple tool with string parameters" do
    with_cassette("tools/simple_tool") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_calculator_tool)

      msg = catch_tool_call(chat) { chat.ask "What is 2 + 3? Use the calculator tool with a=2, b=3" }
      _(msg).wont_be_nil
      _(msg.tool_call?).must_equal true
      _(msg.tool_calls).wont_be :empty?
      call = msg.tool_calls.values.first
      _(call.name).must_equal "calculator"
    end
  end

  it "calls multiple tools" do
    with_cassette("tools/multi_tool") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_calculator_tool)
      chat.with_tool(build_capitalize_tool)

      msg = catch_tool_call(chat) { chat.ask "Add 2+3 with calculator AND capitalize 'hello' with capitalize. Do both at once." }
      _(msg).wont_be_nil
      _(msg.tool_call?).must_equal true
    end
  end

  it "handles tool with complex schema (anyOf)" do
    with_cassette("tools/complex_schema") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_exec_tool)

      msg = catch_tool_call(chat) { chat.ask "Run the exec_command tool with cmd='ls'" }
      _(msg).wont_be_nil
      _(msg.tool_call?).must_equal true
      call = msg.tool_calls.values.first
      _(call.name).must_equal "exec_command"
    end
  end

  it "handles tools with no parameters" do
    with_cassette("tools/no_params_tool") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_noop_tool)

      msg = catch_tool_call(chat) { chat.ask "Call the do_nothing tool." }
      _(msg).wont_be_nil
      _(msg.tool_call?).must_equal true
    end
  end

  it "respects tool choice 'none'" do
    with_cassette("tools/tool_choice_none") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_calculator_tool, choice: :none)

      response = chat.ask "What is 2 + 3? Do NOT use any tools. Just answer."
      _(response.tool_call?).must_equal false
      _(response.content.to_s).must_include "5"
    end
  end

  it "calls a tool multiple times in a row" do
    with_cassette("tools/repeated_tool_calls") do
      chat = RubyLLM.chat(model: "deepseek-v4-flash", provider: :opencode_go, assume_model_exists: true)
      chat.with_tool(build_adder_tool)

      msg = catch_tool_call(chat) { chat.ask "Add 10 and 20 using the adder tool." }
      _(msg).wont_be_nil
      _(msg.tool_call?).must_equal true

      tc = msg.tool_calls.values.first
      result = (tc.arguments["a"].to_i + tc.arguments["b"].to_i).to_s
      chat.add_message(role: :tool, content: result, tool_call_id: tc.id)
      chat.messages.pop if chat.messages.last.tool_call?

      response = chat.complete
      _(response.content.to_s).must_include "30"
    end
  end

  private

  def build_calculator_tool
    build_dynamic_tool("calculator", "Add two numbers", {
      type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"]
    })
  end

  def build_capitalize_tool
    build_dynamic_tool("capitalize", "Capitalize a string", {
      type: "object", properties: { input: { type: "string" } }, required: ["input"]
    })
  end

  def build_exec_tool
    build_dynamic_tool("exec_command", "Execute a shell command", {
      type: "object",
      properties: {
        cmd: { type: "string" },
        workdir: { anyOf: [{ type: "string" }, { type: "null" }] }
      },
      required: ["cmd"]
    })
  end

  def build_noop_tool
    build_dynamic_tool("do_nothing", "Does nothing", {
      type: "object", properties: {}, additionalProperties: false
    })
  end

  def build_adder_tool
    build_dynamic_tool("adder", "Add two numbers", {
      type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"]
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
