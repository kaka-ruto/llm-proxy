module RubyLLM
  module Providers
    class OpenCode < OpenAI
      def api_base
        @config.opencode_api_base || "https://opencode.ai/zen/v1"
      end

      def headers
        {
          "Authorization" => "Bearer #{@config.opencode_api_key}"
        }
      end

      def format_role(role)
        role.to_s
      end

      class << self
        def slug
          "opencode"
        end

        def assume_models_exist?
          true
        end

        def configuration_options
          %i[opencode_api_key opencode_api_base]
        end

        def configuration_requirements
          %i[opencode_api_key]
        end
      end
    end
  end
end

RubyLLM::Provider.register :opencode, RubyLLM::Providers::OpenCode
