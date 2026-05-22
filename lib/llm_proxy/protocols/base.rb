module LLMProxy
  module Protocols
    class Base
      VALID_ROLES = %w[system user assistant tool].freeze
      ROLE_MAP = {
        "developer" => "system",
        "system" => "system",
        "user" => "user",
        "assistant" => "assistant",
        "tool" => "tool",
      }.freeze

      def endpoint
        raise NotImplementedError
      end

      def model_from(body)
        body["model"]
      end

      def normalize(body)
        raise NotImplementedError
      end

      def normalize_role(role)
        ROLE_MAP[role.to_s] || "user"
      end

      def start_events(model:)
        []
      end

      def chunk_events(chunk, model:)
        events = []
        if chunk.content&.length&.> 0
          events.concat(text_delta_events(chunk.content, model:))
        end
        if chunk.thinking&.text&.length&.> 0
          events.concat(thinking_delta_events(chunk.thinking.text, model:))
        end
        if chunk.tool_calls&.any?
          events.concat(tool_call_events(chunk.tool_calls, model:))
        end
        events
      end

      def complete_events(model:, usage: nil)
        []
      end

      def error_events(message, type: "error")
        [{ type: :error, message: message }]
      end

      def text_delta_events(text, model:)
        []
      end

      def thinking_delta_events(text, model:)
        []
      end

      def tool_call_events(tool_calls, model:)
        []
      end
    end
  end
end
