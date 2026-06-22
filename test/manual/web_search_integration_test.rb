require_relative "../test_helper"
require "mocha/minitest"

describe "Manual: Web Search Integration" do
  include VCRTestHelpers

  before do
    LLMProxy.catalog = LLMProxy::ModelCatalog.new(LLMProxy::Config.load(CONFIG_PATH))
    LLMProxy.default_model = "deepseek-v4-flash"
  end

  def searxng_running?
    require "socket"
    socket = TCPSocket.new("127.0.0.1", 8888)
    socket.close
    true
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET
    false
  end

  SEARCH_RESULT = <<~RESULT.strip
    1. Ruby — A Programmer's Best Friend
    https://www.ruby-lang.org
    Ruby is a dynamic, open-source programming language with a focus on simplicity.
  RESULT

  it "executes web_search via Ask SDK and returns text answer" do
    Ask::Tools::WebSearch.any_instance.stubs(:execute).returns(SEARCH_RESULT)

    with_cassette("manual/web_search_sdk") do
      model_config = LLMProxy::Config.load(CONFIG_PATH).models.find { |m| m[:id] == "deepseek-v4-flash" }
      Ask::ModelCatalog.instance.register(
        Ask::ModelInfo.new(id: "deepseek-v4-flash", provider: model_config[:provider], context_window: model_config[:context_window])
      )

      chat = Ask::Agent::Chat.new(
        model: "deepseek-v4-flash",
        tools: [Ask::Tools::WebSearch.new],
        temperature: 0.5
      )
      chat.with_instructions("You are a helpful assistant. When asked about current events or facts, use web_search to find up-to-date information. Always search before answering.")

      response = chat.ask("What is the Ruby programming language? Search the web for it.")
      _(response).wont_be_nil
      _(response.content).wont_be :empty? unless response.tool_call?
    end
  ensure
    Ask::Tools::WebSearch.unstub(:execute) if defined?(Mocha)
  end

  it "verifies SearXNG connectivity" do
    skip "SearXNG not running on port 8888" unless searxng_running?

    uri = URI("http://localhost:8888/search?q=test&format=json")
    res = Net::HTTP.get_response(uri)
    _(res.code).must_equal "200"
    data = JSON.parse(res.body)
    _(data["results"]).must_be_kind_of Array
  end

  it "tests execute_web_search_tools helper with mock chat" do
    server = LLMProxy::Server.new!
    server.instance_variable_set(:@log, Logger.new(File::NULL))

    tool_calls = {
      "call_test" => OpenStruct.new(id: "call_test", name: "web_search", arguments: { "query" => "Ruby on Rails" })
    }
    mock_response = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tool_calls, thinking: nil)

    add_calls = []
    mock_chat = Object.new
    mock_chat.define_singleton_method(:add_message) { |**args| add_calls << args }

    result = server.send(:execute_web_search_tools, mock_chat, mock_response, 0)
    _(result).must_equal true
    _(add_calls.length).must_equal 1
    _(add_calls[0][:role]).must_equal :tool
  end
end
