module LLMProxy
  module Protocols
    class AnthropicMessages < Base
      def endpoint
        "/v1/messages"
      end

      def normalize(body)
        messages = (body["messages"] || []).map do |msg|
          { role: normalize_role(msg["role"]), content: msg["content"] }.tap do |h|
            h[:content] = msg["content"].is_a?(String) ? msg["content"] : extract_anthropic_content(msg["content"])
          end
        end

        tools = (body["tools"] || []).map do |t|
          { name: t["name"], description: t["description"] || "", parameters: t["input_schema"] || t["parameters"] || {} }
        end

        system_prompt = body["system"]
        if system_prompt.is_a?(Array)
          system_prompt = system_prompt.map { |b| b["text"] }.join("\n")
        end

        {
          model: body["model"],
          system: system_prompt,
          messages: messages,
          tools: tools,
          thinking: body.dig("thinking", "type") == "enabled" ? (body.dig("thinking", "budget_tokens") ? "high" : "medium") : nil,
          stream: body["stream"] != false,
          max_tokens: body["max_tokens"],
          temperature: body["temperature"],
          tool_choice: body["tool_choice"],
          parallel_tool_calls: body["parallel_tool_calls"]
        }
      end

      def start_events(model:)
        @next_block_index = 0
        @text_buffer = ""
        @text_block_opened = false
        @text_block_index = nil
        @tool_calls_buffer = []
        @tool_call_indices = []

        [{
          type: "message_start",
          message: {
            id: "msg_#{Time.now.to_i}_#{rand(10000)}",
            type: "message",
            role: "assistant",
            content: [],
            model: model,
            stop_reason: nil,
            stop_sequence: nil,
            usage: { input_tokens: 0, output_tokens: 0 }
          }
        }]
      end

      def chunk_events(chunk, model:)
        events = []

        if chunk.thinking.to_s.length > 0
          events.concat(thinking_events(chunk.thinking.to_s, model:))
        end

        if chunk.content&.length&.> 0
          events.concat(text_delta_events(chunk.content, model:))
        end

        if chunk.tool_calls&.any?
          events.concat(tool_call_events(chunk.tool_calls, model:))
        end

        events
      end

      def complete_events(model:, usage: nil)
        events = []

        if @text_block_opened
          events << { type: "content_block_stop", index: @text_block_index }
        end

        @tool_call_indices.each do |idx|
          events << { type: "content_block_stop", index: idx }
        end

        usage_out = {}
        if usage
          usage_out[:input_tokens] = usage[:input] || 0
          usage_out[:output_tokens] = usage[:output] || 0
          usage_out[:cache_creation_input_tokens] = usage[:cache_creation] if usage[:cache_creation]
          usage_out[:cache_read_input_tokens] = usage[:cache_read] if usage[:cache_read]
        end

        stop_reason = chunk_tool_calls? ? "tool_use" : "end_turn"

        events << {
          type: "message_delta",
          delta: { stop_reason: stop_reason, stop_sequence: nil },
          usage: usage_out
        }

        events << { type: "message_stop" }
        events
      end

      def error_events(message, type: "error")
        [{
          type: "error",
          error: { type: type, message: message }
        }]
      end

      private

      def text_delta_events(text, model:)
        unless @text_block_opened
          @text_block_opened = true
          @text_buffer = text
          @text_block_index = next_block_index
          return [
            {
              type: "content_block_start",
              index: @text_block_index,
              content_block: { type: "text", text: text }
            }
          ]
        end

        @text_buffer += text
        [{
          type: "content_block_delta",
          index: @text_block_index,
          delta: { type: "text_delta", text: text }
        }]
      end

      def thinking_events(text, model:)
        idx = next_block_index
        [{
          type: "content_block_start",
          index: idx,
          content_block: { type: "thinking", thinking: text }
        }, {
          type: "content_block_delta",
          index: idx,
          delta: { type: "thinking_delta", thinking: text }
        }]
      end

      def tool_call_events(tool_calls, model:)
        events = []
        tool_calls.each do |id, tc|
          @tool_calls_buffer << tc
          idx = next_block_index
          @tool_call_indices << idx

          arg_text = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)

          events << {
            type: "content_block_start",
            index: idx,
            content_block: {
              type: "tool_use",
              id: id,
              name: tc.name,
              input: {}
            }
          }

          events << {
            type: "content_block_delta",
            index: idx,
            delta: { type: "input_json_delta", partial_json: arg_text }
          }
        end
        events
      end

      def next_block_index
        idx = @next_block_index
        @next_block_index += 1
        idx
      end

      def chunk_tool_calls?
        @tool_calls_buffer.any?
      end
    end
  end
end
