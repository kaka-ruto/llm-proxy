module Ask
  module Providers
    class OpenCode < OpenAI
      def api_base
        @config.opencode_api_base || ENV["OPENCODE_API_BASE"] || "https://opencode.ai/zen/v1"
      end

      def headers
        {
          "Authorization" => "Bearer #{@config.opencode_api_key || @config.api_key}"
        }
      end

      def assume_models_exist?
        true
      end

      class << self
        def slug; "opencode"; end
        def configuration_options; %i[opencode_api_key opencode_api_base]; end
        def configuration_requirements; %i[opencode_api_key]; end
      end
    end
  end
end

Ask::Provider.register :opencode, Ask::Providers::OpenCode
