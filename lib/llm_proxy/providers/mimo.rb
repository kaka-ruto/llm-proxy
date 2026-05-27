module RubyLLM
  module Providers
    class Mimo < OpenAI
      def api_base
        @config.mimo_api_base || "https://token-plan-sgp.xiaomimimo.com/v1"
      end

      def headers
        {
          "Authorization" => "Bearer #{@config.mimo_api_key}"
        }
      end

      def format_role(role)
        role.to_s
      end

      class << self
        def slug
          "mimo"
        end

        def assume_models_exist?
          true
        end

        def configuration_options
          %i[mimo_api_key mimo_api_base]
        end

        def configuration_requirements
          %i[mimo_api_key]
        end
      end
    end
  end
end

RubyLLM::Provider.register :mimo, RubyLLM::Providers::Mimo
