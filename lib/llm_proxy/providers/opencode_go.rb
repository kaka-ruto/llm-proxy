module Ask
  module Providers
    class OpenCodeGo < OpenAI
      def api_base
        @config.opencode_go_api_base || ENV["OPENCODE_GO_API_BASE"] || "https://opencode.ai/zen/go/v1"
      end

      def headers
        {
          "Authorization" => "Bearer #{@config.opencode_go_api_key || @config.api_key}"
        }
      end

      def assume_models_exist?
        true
      end

      class << self
        def slug; "opencode_go"; end
        def configuration_options; %i[opencode_go_api_key opencode_go_api_base]; end
        def configuration_requirements; %i[opencode_go_api_key]; end
      end
    end
  end
end

Ask::Provider.register :opencode_go, Ask::Providers::OpenCodeGo
