require "base64"

module LLMProxy
  module Protocols
    class OpenAIResponses < Base
      THINKING_MAGIC = "anthropic-thinking-v1:"

      def endpoint
        "/v1/responses"
      end

      def normalize(body, logger: nil)
        input = body["input"]
        input = case input
                when String then [{ "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => input }] }]
                when Array then input
                else []
                end
        prev_messages = input.filter_map { |item| response_item_to_message(item) }
        raw_tools = body["tools"] || []
        tools = raw_tools.filter_map do |t|
          type = t["type"]
          fn = case type
               when "function" then t["function"] || t
               when "custom" then t
               else
                 logger&.debug("  Non-function tool filtered out: #{type}")
                 next
               end
          name = fn["name"].to_s.strip
          next if name.empty?
          params = fn["parameters"]
          next unless params.is_a?(Hash)
          { name: name, description: fn["description"] || "", parameters: params }
        end

        {
          model: body["model"],
          system: body["instructions"] || body.dig("system", "content"),
          messages: prev_messages,
          tools: tools,
          thinking: body.dig("reasoning", "effort"),
          stream: body["stream"] != false,
          max_tokens: body["max_output_tokens"] || body["max_tokens"],
          temperature: body["temperature"],
          tool_choice: body["tool_choice"],
          parallel_tool_calls: body["parallel_tool_calls"]
        }
      end

      def start_events(model:)
        @model_name = model
        @response_id = "resp_#{Time.now.to_i}"
        @message_item_id = "msg_#{Time.now.to_i}"
        @message_index = nil
        @message_text = ""
        @message_opened = false
        @message_closed = false
        @tool_calls = {}
        @reasoning_blocks = {}
        @next_output_index = 0

        [{
          type: "response.created",
          response: {
            id: @response_id,
            object: "response",
            created_at: Time.now.to_i,
            status: "in_progress",
            model: model,
            output: []
          }
        }]
      end

      def chunk_events(chunk, model:)
        events = []

        if chunk.thinking.to_s.length > 0
          events.concat(reasoning_events(chunk.thinking.to_s))
        end

        if chunk.content&.length&.> 0
          events.concat(text_events(chunk.content))
        end

        if chunk.tool_calls&.any?
          events.concat(tool_call_events(chunk.tool_calls))
        end

        events
      end

      def complete_events(model:, usage: nil)
        events = []

        events.concat(close_message) if @message_opened && !@message_closed

        @tool_calls.each_value do |tc|
          next if tc[:closed]
          args = tc[:arguments].empty? ? "{}" : tc[:arguments]
          events << {
            type: "response.function_call_arguments.done",
            item_id: tc[:id],
            output_index: tc[:index],
            arguments: args
          }
          events << {
            type: "response.output_item.done",
            output_index: tc[:index],
            item: {
              id: tc[:id], type: "function_call", status: "completed",
              call_id: tc[:id], name: tc[:name], arguments: args
            }
          }
          tc[:closed] = true
        end

        @reasoning_blocks.each_value do |rb|
          next if rb[:closed]
          events << {
            type: "response.reasoning_summary_text.done",
            item_id: rb[:id], output_index: rb[:index], summary_index: 0, text: rb[:text]
          }
          events << {
            type: "response.output_item.done",
            output_index: rb[:index],
            item: {
              id: rb[:id], type: "reasoning", status: "completed",
              summary: rb[:text].empty? ? [] : [{ type: "summary_text", text: rb[:text] }],
              encrypted_content: encode_thinking(rb[:text])
            }
          }
          rb[:closed] = true
        end

        events << {
          type: "response.completed",
          response: response_payload("completed", usage:)
        }

        events
      end

      def cleanup_accumulated_tool_calls(exclude_names: [])
        @tool_calls.delete_if { |_id, tc| exclude_names.include?(tc[:name]) }
      end

      def error_events(message, type: "error")
        [{
          type: "error",
          error: { message: message, type: type }
        }]
      end

      private

      def response_payload(status, usage: nil)
        output = []

        @reasoning_blocks.each_value do |rb|
          output << [rb[:index], {
            id: rb[:id], type: "reasoning", status: "completed",
            summary: rb[:text].empty? ? [] : [{ type: "summary_text", text: rb[:text] }],
            encrypted_content: encode_thinking(rb[:text])
          }]
        end

        if @message_opened && !@message_text.empty? && @message_index
          output << [@message_index, {
            id: @message_item_id, type: "message", status: "completed", role: "assistant",
            content: [{ type: "output_text", text: @message_text, annotations: [] }]
          }]
        end

        @tool_calls.each_value do |tc|
          args = tc[:arguments].empty? ? "{}" : tc[:arguments]
          output << [tc[:index], {
            id: tc[:id], type: "function_call", status: "completed",
            call_id: tc[:id], name: tc[:name], arguments: args
          }]
        end

        output.sort_by!(&:first)
        sorted = output.map(&:last)

        payload = {
          id: @response_id,
          object: "response",
          created_at: Time.now.to_i,
          status: status,
          model: @model_name,
          output: sorted
        }

        if usage
          input = usage[:input] || 0
          output = usage[:output] || 0
          payload[:usage] = { input_tokens: input, output_tokens: output, total_tokens: input + output }
        end

        payload
      end

      def text_events(text)
        @message_text = "#{@message_text}#{text}"

        if @message_opened
          return [{
            type: "response.output_text.delta",
            item_id: @message_item_id,
            output_index: @message_index,
            content_index: 0,
            delta: text
          }]
        end

        @message_index = next_index
        @message_opened = true

        [
          {
            type: "response.output_item.added",
            output_index: @message_index,
            item: {
              id: @message_item_id, type: "message", status: "in_progress",
              role: "assistant", content: []
            }
          },
          {
            type: "response.content_part.added",
            item_id: @message_item_id,
            output_index: @message_index,
            content_index: 0,
            part: { type: "output_text", text: "", annotations: [] }
          },
          {
            type: "response.output_text.delta",
            item_id: @message_item_id,
            output_index: @message_index,
            content_index: 0,
            delta: text
          }
        ]
      end

      def close_message
        return [] unless @message_opened && !@message_closed
        @message_closed = true

        [
          {
            type: "response.output_text.done",
            item_id: @message_item_id,
            output_index: @message_index,
            content_index: 0,
            text: @message_text
          },
          {
            type: "response.content_part.done",
            item_id: @message_item_id,
            output_index: @message_index,
            content_index: 0,
            part: { type: "output_text", text: @message_text, annotations: [] }
          },
          {
            type: "response.output_item.done",
            output_index: @message_index,
            item: {
              id: @message_item_id, type: "message", status: "completed",
              role: "assistant",
              content: @message_text.empty? ? [] : [{ type: "output_text", text: @message_text, annotations: [] }]
            }
          }
        ]
      end

      def reasoning_events(text)
        key = :reasoning
        state = @reasoning_blocks[key]

        if state.nil?
          idx = next_index
          id = "rs_#{Time.now.to_i}_#{idx}"
          state = { id: id, index: idx, text: "", closed: false }
          @reasoning_blocks[key] = state

          return [
            {
              type: "response.output_item.added",
              output_index: idx,
              item: { id: id, type: "reasoning", status: "in_progress", summary: [], encrypted_content: nil }
            },
            {
              type: "response.reasoning_summary_text.delta",
              item_id: id, output_index: idx, summary_index: 0, delta: text
            }
          ]
        end

        state[:text] += text
        [{
          type: "response.reasoning_summary_text.delta",
          item_id: state[:id], output_index: state[:index], summary_index: 0, delta: text
        }]
      end

      def tool_call_events(tool_calls)
        events = []
        tool_calls.each do |id, tc|
          key = id || @tool_calls.keys.reverse.find { |k| k != nil && !@tool_calls[k][:closed] }
          state = key ? @tool_calls[key] : nil

          arg_text = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)

          if state.nil?
            events.concat(close_message) if @message_opened && !@message_closed
            idx = next_index
            call_id = id || tc.name || "call_#{idx}"
            state = { id: call_id, index: idx, name: tc.name || call_id, arguments: "", closed: false }
            @tool_calls[call_id] = state

            events << {
              type: "response.output_item.added",
              output_index: idx,
              item: { id: call_id, type: "function_call", status: "in_progress",
                      call_id: call_id, name: state[:name], arguments: "" }
            }

            if arg_text.length > 0
              state[:arguments] = arg_text
              events << {
                type: "response.function_call_arguments.delta",
                item_id: state[:id], output_index: state[:index], delta: arg_text
              }
            end
          else
            # ChatChunk from ask-agent yields CUMULATIVE arguments (full text so far),
            # not individual deltas. Determine the delta by comparing with what we have.
            prev = state[:arguments]
            if arg_text.length > prev.length
              delta = arg_text[prev.length..]
              state[:arguments] = arg_text
              events << {
                type: "response.function_call_arguments.delta",
                item_id: state[:id], output_index: state[:index], delta: delta
              }
            end
          end
        end
        events
      end

      def next_index
        idx = @next_output_index
        @next_output_index += 1
        idx
      end

      def encode_thinking(text)
        return nil if text.nil? || text.empty?
        payload = { type: "thinking", thinking: text, signature: "" }
        raw = JSON.generate(payload, separators: [",", ":"])
        "#{THINKING_MAGIC}#{Base64.urlsafe_encode64(raw)}"
      end

      def response_item_to_message(item)
        case item["type"]
        when "message"
          { role: normalize_role(item["role"] || "user"), content: extract_content(item["content"]) }
        when "function_call"
          { role: :assistant, content: nil,
            tool_calls: [{ id: item["call_id"], type: "function",
                           function: { name: item["name"], arguments: item["arguments"] } }] }
        when "function_call_output"
          { role: :tool, content: item["output"], tool_call_id: item["call_id"] }
        when "reasoning"
          summary = item["summary"] || []
          text = summary.map { |s| s["text"] }.compact.join("")
          { role: :assistant, content: nil, summary: summary, thinking: text }
        when "item_reference"
          nil
        else
          { role: "user", content: item.to_s }
        end
      end

      def extract_content(content_items)
        return "" unless content_items.is_a?(Array)
        content_items.map do |c|
          case c["type"]
          when "input_text" then c["text"]
          when "output_text" then c["text"]
          when "refusal" then c["refusal"]
          else ""
          end
        end.join
      end
    end
  end
end
