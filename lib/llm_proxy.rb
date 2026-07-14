require "yaml"
require "json"
require "sinatra/base"

require "ask/agent"
require "ask/tools/shell/apply_patch"
require "ask/web_search"

require "ask/llm/catalog"

module LLMProxy
  class Error < StandardError; end
  class ToolCallStop < Error; end

  class << self
    attr_accessor :default_model
  end

  self.default_model = nil
end

require_relative "llm_proxy/auth"
require_relative "llm_proxy/config"
require_relative "llm_proxy/protocols/base"
require_relative "llm_proxy/protocols/openai_completions"
require_relative "llm_proxy/protocols/openai_responses"
require_relative "llm_proxy/protocols/anthropic_messages"
require_relative "llm_proxy/goals"
require_relative "llm_proxy/codex"
require_relative "llm_proxy/zcode"
require_relative "llm_proxy/mcp_server"

require_relative "llm_proxy/cli"
require_relative "llm_proxy/server"
