module Ask
  module Providers
    class Mimo < OpenAI
      def api_base
        @config.mimo_api_base || ENV["MIMO_API_BASE"] || "https://token-plan-sgp.xiaomimimo.com/v1"
      end

      def headers
        {
          "Authorization" => "Bearer #{@config.mimo_api_key || @config.api_key}"
        }
      end

      def assume_models_exist?
        true
      end

      class << self
        def slug; "mimo"; end
        def configuration_options; %i[mimo_api_key mimo_api_base]; end
        def configuration_requirements; %i[mimo_api_key]; end
      end
    end
  end
end

Ask::Provider.register :mimo, Ask::Providers::Mimo
