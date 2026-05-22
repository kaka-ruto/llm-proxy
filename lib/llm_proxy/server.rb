require "rack"
require "logger"
require "fileutils"

module LLMProxy
  class Server
    LOG_DIR = File.expand_path("../../logs", __dir__)
    LOG_FILE = File.join(LOG_DIR, "development.log")

    def initialize
      FileUtils.mkdir_p(LOG_DIR)
      @logger = Logger.new(LOG_FILE, "daily")
      @logger.level = Logger::DEBUG
      @logger.formatter = proc { |severity, datetime, _progname, msg|
        "[#{datetime.strftime("%Y-%m-%d %H:%M:%S %z")}] #{severity}: #{msg}\n"
      }
      @logger.info("LLM Proxy server initialized")
      @protocols = {
        "/v1/chat/completions" => Protocols::OpenAICompletions,
        "/v1/responses" => Protocols::OpenAIResponses,
        "/v1/messages" => Protocols::AnthropicMessages,
      }
    end

    def call(env)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      req = Rack::Request.new(env)
      body_str = env["rack.input"].read
      env["rack.input"].rewind

      @logger.info("#{req.request_method} #{req.path_info}")
      @logger.debug("  Headers: #{env.select { |k, _| k.start_with?("HTTP_") }.to_json}")
      @logger.debug("  Body: #{truncate_body(body_str)}")

      result = handle_request(req, body_str)

      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)
      status, headers, _body = result
      @logger.info("  => #{status} (#{duration}ms)")
      result
    rescue => e
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)
      @logger.error("  ! #{e.class}: #{e.message} (#{duration}ms)")
      @logger.debug("  #{e.backtrace&.first(5)&.join("\n    ")}")
      json_response({ error: { message: e.message } }, 500)
    end

    private

    def handle_request(req, body_str)
      body = JSON.parse(body_str) rescue nil

      case [req.request_method, req.path_info]
      in ["GET", "/health"]
        json_response({ status: "ok", models: LLMProxy.catalog.all.size })
      in ["GET", "/v1/models"]
        json_response({ object: "list", data: LLMProxy.catalog.to_openai_list })
      in ["POST", path] if @protocols.key?(path) && body
        handle_stream(body, @protocols[path].new)
      else
        json_response({ error: "Not found" }, 404)
      end
    end

    def handle_stream(body, protocol)
      model_id = protocol.model_from(body)
      model_info = LLMProxy.catalog.lookup(model_id)

      unless model_info
        @logger.warn("  Unknown model: #{model_id}")
        return error_stream("Unknown model: #{model_id}")
      end

      normalized = protocol.normalize(body)
      msg_count = (normalized[:messages] || []).length
      tool_count = (normalized[:tools] || []).length
      @logger.info("  model=#{model_id} (#{model_info.provider}) msgs=#{msg_count} tools=#{tool_count}")
      @logger.debug("  system=#{normalized[:system]&.length&.>(50) ? normalized[:system][..50] + '...' : normalized[:system].inspect}")
      @logger.debug("  thinking=#{normalized[:thinking].inspect} stream=#{normalized[:stream]} max_tokens=#{normalized[:max_tokens]} temp=#{normalized[:temperature]}")

      is_streaming = normalized[:stream] != false
      start_events = protocol.start_events(model: model_info.id)

      unless is_streaming
        chat = build_chat(model_info, normalized)
        chat.complete
        final_msg = chat.messages.last
        usage = token_usage(final_msg)
        @logger.info("  Usage: #{usage.inspect}")
        payload = protocol.complete_events(model: model_info.id, usage: usage)
        completed = payload.find { |e| e.is_a?(Hash) && e[:type] == "response.completed" }
        return json_response(completed || { type: "response.completed", response: { id: "resp_0", status: "completed", model: model_info.id, output: [] } })
      end

      body_writer = StreamBody.new

      Thread.new do
        begin
          chat = build_chat(model_info, normalized)
          chat.before_tool_call { raise ToolCallStop }

          @logger.debug("  Starting stream...")
          body_writer.write(SSE.format(start_events))
          event_count = start_events.length

          chat.complete do |chunk|
            events = protocol.chunk_events(chunk, model: model_info.id)
            unless events.empty?
              body_writer.write(SSE.format(events))
              event_count += events.length
              # Log every 50th event to avoid log spam
              if event_count % 50 == 0
                @logger.debug("  Streamed #{event_count} events...")
              end
            end
          end

          @logger.info("  Streamed #{event_count} events total")
          send_complete(protocol, chat, body_writer, model_info)

        rescue ToolCallStop
          @logger.info("  Tool call stop (streamed tool calls)")
          send_complete(protocol, chat, body_writer, model_info)
        rescue => e
          @logger.error("Error: #{e.class}: #{e.message}")
          @logger.debug("  #{e.backtrace&.first(5)&.join("\n    ")}")
          body_writer.write(SSE.format(protocol.error_events(e.message)))
          body_writer.write(SSE.format(protocol.complete_events(model: model_info.id)))
        ensure
          body_writer.write("data: [DONE]\n\n")
          body_writer.close
        end
      end

      [200, {
        "Content-Type" => "text/event-stream",
        "Cache-Control" => "no-cache",
        "X-Accel-Buffering" => "no",
      }, body_writer]
    end

    def build_chat(model_info, normalized)
      chat = RubyLLM.chat(model: model_info.id, provider: model_info.provider.to_sym, assume_model_exists: true)
      chat.with_instructions(normalized[:system]) if normalized[:system]
      chat.with_thinking(effort: normalized[:thinking].to_sym) if normalized[:thinking]
      chat.with_temperature(normalized[:temperature]) if normalized[:temperature]

      (normalized[:tools] || []).each do |t|
        next if t[:name].nil? || t[:name].strip.empty?
        tool_class = build_dynamic_tool(t[:name], t[:description], t[:parameters])
        chat.with_tool(tool_class)
      end

      (normalized[:messages] || []).each do |msg|
        next unless msg[:content]
        role = msg[:role].to_s.to_sym
        attrs = { role: role, content: msg[:content] }
        attrs[:tool_call_id] = msg[:tool_call_id] if msg[:tool_call_id]
        chat.add_message(attrs)
      end

      chat
    end

    def send_complete(protocol, chat, writer, model_info)
      final_msg = chat&.messages&.last
      usage = token_usage(final_msg)
      @logger.info("  Usage: #{usage.inspect}")
      @logger.info("  Finish reason: #{final_msg&.tool_call? ? 'tool_calls' : 'stop'}")
      complete_events = protocol.complete_events(model: model_info.id, usage: usage)
      completed = complete_events.find { |e| e.is_a?(Hash) && e[:type] == "response.completed" }
      @logger.debug("  complete_events count=#{complete_events.length}")
      @logger.debug("  response.completed output items=#{completed&.dig(:response, :output)&.length || 0}") if completed
      writer.write(SSE.format(complete_events))
    end

    def token_usage(msg)
      return nil unless msg&.tokens
      { input: msg.input_tokens, output: msg.output_tokens }.compact
    end

    def error_stream(message)
      body = StreamBody.new
      body.write(SSE.format({ type: "error", error: { message: message } }))
      body.write(SSE.format({ type: "response.completed", response: { id: "resp_0", status: "completed", model: "unknown", output: [] } }))
      body.write("data: [DONE]\n\n")
      body.close
      [200, { "Content-Type" => "text/event-stream" }, body]
    end

    def json_response(data, status = 200)
      [status, { "Content-Type" => "application/json" }, [JSON.generate(data)]]
    end

    def truncate_body(str)
      return "nil" unless str
      str = str.strip
      return "empty" if str.empty?
      str.length > 500 ? str[..500] + "..." : str
    end

    def build_dynamic_tool(name, description, parameters)
      klass = Class.new(RubyLLM::Tool) do
        description(description || "")
        (parameters || {}).dig("properties")&.each do |prop_name, prop_schema|
          param prop_name.to_sym, type: prop_schema["type"] || "string", description: prop_schema["description"] || ""
        end
        define_method(:execute) { |**| raise LLMProxy::ToolCallStop }
      end
      klass.define_method(:name) { name }
      klass
    end
  end

  class StreamBody
    def initialize
      @queue = Queue.new
      @closed = false
    end

    def write(data)
      @queue << data unless @closed
    end

    def close
      @closed = true
      @queue << nil
    end

    def each
      while (data = @queue.pop)
        yield data
      end
    end
  end

  module SSE
    def self.format(events)
      case events
      when Array then events.map { |e| "data: #{JSON.generate(e)}\n\n" }.join
      when Hash  then "data: #{JSON.generate(events)}\n\n"
      else events.to_s
      end
    end
  end
end
