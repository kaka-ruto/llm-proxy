require "ruby_llm"
require "yaml"
require "json"
require "sinatra/base"

module LLMProxy
  class Error < StandardError; end
  class ToolCallStop < Error; end

  class << self
    attr_accessor :protocols, :catalog, :default_model
  end

  self.protocols = {}
  self.catalog = nil
  self.default_model = nil
end

require_relative "llm_proxy/providers/opencode"
require_relative "llm_proxy/providers/opencode_go"
require_relative "llm_proxy/auth"
require_relative "llm_proxy/config"
require_relative "llm_proxy/model_catalog"
require_relative "llm_proxy/protocols/base"
require_relative "llm_proxy/protocols/openai_completions"
require_relative "llm_proxy/protocols/openai_responses"
require_relative "llm_proxy/protocols/anthropic_messages"
require_relative "llm_proxy/protocols/models_endpoint"
require_relative "llm_proxy/codex"
require_relative "llm_proxy/cli"
require_relative "llm_proxy/server"
