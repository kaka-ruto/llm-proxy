module LLMProxy
  module Protocols
    class ModelsEndpoint < Base
      def endpoint
        "GET /v1/models"
      end
    end
  end
end
