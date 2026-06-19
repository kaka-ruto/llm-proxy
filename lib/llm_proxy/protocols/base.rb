module LLMProxy
  module Protocols
    class Base
      HEREDOC_RE = /<<[- ]?(\w+)(?!\s*['"])/.freeze

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
        if chunk.thinking.to_s.length > 0
          events.concat(thinking_delta_events(chunk.thinking.to_s, model:))
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

      # Normalize tool call arguments to prevent shell expansion of unquoted
      # heredocs. Models often generate << EOF instead of << 'EOF', which
      # causes $variables and backticks to be interpreted by the shell.
      def normalize_heredocs(args)
        case args
        when Hash then normalize_hash(args)
        when String then fix_heredocs(args)
        else args
        end
      end

      private

      def normalize_hash(hash)
        hash.each_with_object({}) do |(k, v), result|
          result[k] = case v
          when String then fix_heredocs(v)
          when Hash then normalize_hash(v)
          when Array then v.map { |e| e.is_a?(Hash) ? normalize_hash(e) : e }
          else v
          end
        end
      end

      def fix_heredocs(str)
        str.gsub(HEREDOC_RE) {
          $&.include?("-") ? "<<-'#$1'" : "<< '#$1'"
        }
      end
    end
  end
end
