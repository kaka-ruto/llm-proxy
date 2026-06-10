module LLMProxy
  module Protocols
    class OpenAICompletions < Base
      def endpoint
        "/v1/chat/completions"
      end

      def normalize(body)
        messages = (body["messages"] || []).map do |msg|
          { role: normalize_role(msg["role"]), content: extract_content(msg) }.tap do |h|
            h[:tool_calls] = msg["tool_calls"] if msg["tool_calls"]
            h[:tool_call_id] = msg["tool_call_id"] if msg["tool_call_id"]
          end
        end

        tools = (body["tools"] || []).map do |t|
          fn = t["function"] || t
          { name: fn["name"], description: fn["description"] || "", parameters: fn["parameters"] || {} }
        end

        {
          model: body["model"],
          system: extract_system(messages),
          messages: messages.reject { |m| m[:role] == "system" },
          tools: tools,
          thinking: body.dig("reasoning_effort"),
          stream: body["stream"] != false,
          max_tokens: body["max_tokens"] || body["max_completion_tokens"],
          temperature: body["temperature"]
        }
      end

      def start_events(model:)
        []
      end

      def chunk_events(chunk, model:)
        events = []
        choice = { index: 0 }

        if chunk.content&.length&.> 0
          choice[:delta] = { content: chunk.content }
          events << { choices: [choice] }
        end

        if chunk.thinking.to_s.length > 0
          choice[:delta] = { reasoning_content: chunk.thinking.text }
          events << { choices: [choice] }
        end

        if chunk.tool_calls&.any?
          chunk.tool_calls.each_with_index do |(id, tc), idx|
            events << {
              choices: [{
                index: 0,
                delta: {
                  tool_calls: [{
                    index: idx,
                    id: id,
                    type: "function",
                    function: { name: tc.name, arguments: (tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)) }
                  }]
                }
              }]
            }
          end
        end

        events
      end

      def complete_events(model:, usage: nil)
        choice = { index: 0, delta: {}, finish_reason: "stop" }
        if usage
          choice[:finish_reason] = "stop"
          choice[:usage] = usage
        end
        [{ choices: [choice], usage: usage }]
      end

      private

      def extract_content(msg)
        c = msg["content"]
        return c unless c.is_a?(Array)
        c.map { |part| part["type"] == "text" ? part["text"] : "" }.join
      end

      def extract_system(messages)
        sys = messages.select { |m| m[:role] == "system" }
        sys.map { |m| m[:content] }.join("\n").empty? ? nil : sys.map { |m| m[:content] }.join("\n")
      end
    end
  end
end
