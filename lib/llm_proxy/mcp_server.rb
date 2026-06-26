# frozen_string_literal: true

require "ask/mcp"
require "ask-tools-shell"
require "ask-web-search"

module LLMProxy
  # MCP server exposing a curated set of ask-rb tools over stdio.
  # Start with: bin/llm-proxy mcp
  module MCPServer
    TOOLS = [
      Ask::Tools::ApplyPatch.new,
      Ask::Tools::WebSearch.new
    ].freeze

    def self.start
      Ask::MCP::Server.start_stdio(
        name: "llm-proxy",
        tools: TOOLS,
        capabilities: { tools: {} },
        debug: ENV["DEBUG"] == "1"
      )
    end
  end
end
