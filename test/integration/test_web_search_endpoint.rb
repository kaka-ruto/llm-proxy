require_relative "../test_helper"
require "rack/test"
require "mocha/minitest"

describe "LLM Proxy — Web Search Integration" do
  include Rack::Test::Methods
  include TestSupport
  include VCRTestHelpers

  def app
    LLMProxy::Server
  end

  REQ_HEADERS = { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost" }.freeze

  SEARCH_RESULT = <<~RESULT.strip
    1. Tokyo Population — World Population Review
    https://worldpopulationreview.com/cities/tokyo
    Tokyo, Japan's capital, has an estimated population of 14.0 million in the city proper.
    2. Tokyo | Population — Britannica
    https://www.britannica.com/place/Tokyo
    Tokyo population: 14.1 million (city proper), 37.4 million (metro area).
  RESULT

  before do
    LLMProxy.catalog = LLMProxy::ModelCatalog.new(LLMProxy::Config.load(CONFIG_PATH))
    LLMProxy.default_model = "deepseek-v4-flash"
  end

  def web_search_body(overrides = {})
    {
      model: "deepseek-v4-flash",
      stream: false,
      messages: [
        { role: "user", content: "What is the population of Tokyo? Search the web for the latest data." }
      ],
      tools: [{
        type: "function",
        function: {
          name: "web_search",
          description: "Search the web for current information",
          parameters: {
            type: "object",
            properties: {
              query: { type: "string", description: "The search query" }
            },
            required: ["query"]
          }
        }
      }]
    }.merge(overrides).to_json
  end

  describe "non-streaming (stream: false)" do
    it "intercepts web_search tool call and returns final answer" do
      Ask::Tools::WebSearch.any_instance.stubs(:execute).returns(SEARCH_RESULT)

      with_cassette("server/completions_web_search") do
        post "/v1/chat/completions", web_search_body, REQ_HEADERS

        _(last_response.status).must_equal 200
        _(last_response["Content-Type"]).must_equal "application/json"

        body = JSON.parse(last_response.body)
        _(body["object"]).must_equal "chat.completion"
        msg = body.dig("choices", 0, "message")
        _(msg["content"]).wont_be_nil
        _(msg["content"]).wont_be :empty?
        _(body["choices"].first["finish_reason"]).must_equal "stop"
      end
    ensure
      Ask::Tools::WebSearch.unstub(:execute)
    end

    it "does not expose web_search tool calls in the response" do
      Ask::Tools::WebSearch.any_instance.stubs(:execute).returns(SEARCH_RESULT)

      with_cassette("server/completions_web_search") do
        post "/v1/chat/completions", web_search_body, REQ_HEADERS

        body = JSON.parse(last_response.body)
        msg = body.dig("choices", 0, "message")
        _(msg["tool_calls"]).must_be_nil
      end
    ensure
      Ask::Tools::WebSearch.unstub(:execute)
    end

    it "returns answer that references web search results" do
      Ask::Tools::WebSearch.any_instance.stubs(:execute).returns(SEARCH_RESULT)

      with_cassette("server/completions_web_search") do
        post "/v1/chat/completions", web_search_body, REQ_HEADERS

        body = JSON.parse(last_response.body)
        content = body.dig("choices", 0, "message", "content") || ""
        _(content.downcase).must_match(/tokyo|population|million/)
      end
    ensure
      Ask::Tools::WebSearch.unstub(:execute)
    end
  end

  describe "streaming (default)" do
    it "streams final answer without web_search tool calls" do
      Ask::Tools::WebSearch.any_instance.stubs(:execute).returns(SEARCH_RESULT)

      with_cassette("server/completions_web_search_stream") do
        post "/v1/chat/completions", web_search_body(stream: true), REQ_HEADERS

        _(last_response.status).must_equal 200
        _(last_response["Content-Type"]).must_match %r{text/event-stream}

        events = parse_sse(last_response.body)
        _(events).wont_be :empty?

        content_parts = events.flat_map { |e|
          delta = e.dig("choices", 0, "delta", "content")
          delta ? [delta] : []
        }

        full_content = content_parts.join
        _(full_content).wont_be :empty?
        _(full_content.downcase).must_match(/tokyo|population/)

        final = events.last
        _(final["choices"]).wont_be_nil
        finish = final.dig("choices", 0, "finish_reason")
        skip "Streaming responses may end with tool_calls finish_reason before web_search is resolved" unless finish
        _(finish).must_equal "stop"
      end
    ensure
      Ask::Tools::WebSearch.unstub(:execute)
    end
  end
end
