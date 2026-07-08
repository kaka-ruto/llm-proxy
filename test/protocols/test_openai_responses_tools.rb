# frozen_string_literal: true

require_relative "../test_helper"

describe LLMProxy::Protocols::OpenAIResponses do
  include TestSupport

  before do
    @protocol = LLMProxy::Protocols::OpenAIResponses.new
  end

  describe "tool normalization — all types pass through" do
    it "passes through web_search tools" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "web_search", "name" => "web_search", "description" => "Search the web",
            "parameters" => { "type" => "object", "properties" => { "query" => { "type" => "string" } } } }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:name]).must_equal "web_search"
    end

    it "passes through image_generation tools" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "image_generation", "name" => "image_generation", "description" => "Generate an image",
            "parameters" => { "type" => "object", "properties" => { "prompt" => { "type" => "string" } } } }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:name]).must_equal "image_generation"
    end

    it "passes through namespace tools" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "namespace", "name" => "namespace", "description" => "Tool namespace",
            "parameters" => { "type" => "object" } }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:name]).must_equal "namespace"
    end

    it "passes through tool_search tools" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "tool_search", "name" => "tool_search", "description" => "Search for a tool",
            "parameters" => { "type" => "object", "properties" => { "query" => { "type" => "string" } } } }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:name]).must_equal "tool_search"
    end

    it "passes through custom tools (apply_patch) even without parameters key" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "custom", "name" => "apply_patch", "description" => "Apply a patch" }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:name]).must_equal "apply_patch"
    end

    it "mixes all tool types together" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "function", "function" => { "name" => "exec_command", "description" => "Run command",
            "parameters" => { "type" => "object", "properties" => { "cmd" => { "type" => "string" } } } } },
          { "type" => "web_search", "name" => "web_search", "description" => "Search",
            "parameters" => { "type" => "object", "properties" => { "query" => { "type" => "string" } } } },
          { "type" => "custom", "name" => "apply_patch", "description" => "Patch",
            "parameters" => { "type" => "object" } }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 3
      names = tools.map { |t| t[:name] }
      _(names).must_include "exec_command"
      _(names).must_include "web_search"
      _(names).must_include "apply_patch"
    end

    it "creates a default empty parameters hash when none provided" do
      body = {
        "input" => [],
        "tools" => [
          { "type" => "custom", "name" => "bare_tool", "description" => "No params" }
        ]
      }
      tools = @protocol.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:parameters]).must_equal({ "type" => "object" })
    end
  end

  describe "AnthropicMessages protocol — all tool types pass through" do
    before do
      @anthropic = LLMProxy::Protocols::AnthropicMessages.new
    end

    it "passes through web_search tools" do
      body = {
        "messages" => [{ "role" => "user", "content" => "hi" }],
        "tools" => [
          { "type" => "web_search", "name" => "web_search", "description" => "Search",
            "input_schema" => { "type" => "object", "properties" => { "query" => { "type" => "string" } } } }
        ]
      }
      tools = @anthropic.normalize(body)[:tools]
      _(tools.size).must_equal 1
      _(tools.first[:name]).must_equal "web_search"
    end
  end
end
