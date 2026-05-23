require "sinatra/base"
require "logger"
require "fileutils"

module LLMProxy
  class Server < Sinatra::Base
    LOG_DIR = File.expand_path("../../logs", __dir__)
    LOG_FILE = File.join(LOG_DIR, "development.log")

    configure do
      FileUtils.mkdir_p(LOG_DIR)
      File.chmod(0700, LOG_DIR)
      logger = Logger.new(LOG_FILE, "daily")
      File.chmod(0600, LOG_FILE) if File.exist?(LOG_FILE)
      logger.level = Logger::DEBUG
      logger.formatter = proc { |severity, datetime, _progname, msg|
        "[#{datetime.strftime("%Y-%m-%d %H:%M:%S %z")}] #{severity}: #{msg}\n"
      }
      set :logger, logger
      set :server, :puma
      set :show_exceptions, false
      set :raise_errors, false
    end

    before do
      @log = settings.logger
      @log.info("#{request.request_method} #{request.path_info}")

      headers = request.env.select { |k, _| k.start_with?("HTTP_") }
      headers = headers.merge("HTTP_AUTHORIZATION" => "[REDACTED]") if headers.key?("HTTP_AUTHORIZATION")
      @log.debug("  Headers: #{headers.to_json}")

      body_str = request.body.read
      request.body.rewind
      safe_body = body_str.gsub(/(?:"apiKey"|"key")\s*:\s*"[^"]+"/, '\1: "[REDACTED]"')
      @log.debug("  Body: #{safe_body}")
      @request_body = body_str
      @_streaming = false
      @_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    after do
      unless @_streaming
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @_start_time) * 1000).round(1)
        @log.info("  => #{response.status} (#{duration}ms)")
      end
    end

    get "/health" do
      content_type :json
      { status: "ok", models: LLMProxy.catalog.all.size }.to_json
    end

    get "/v1/models" do
      content_type :json
      { object: "list", data: LLMProxy.catalog.to_openai_list }.to_json
    end



    [
      Protocols::OpenAICompletions,
      Protocols::OpenAIResponses,
      Protocols::AnthropicMessages,
    ].each do |protocol_class|
      endpoint = protocol_class.new.endpoint

      post endpoint do
        @_streaming = true
        content_type "text/event-stream"
        headers "Cache-Control" => "no-cache"
        headers "X-Accel-Buffering" => "no"

        stream(:keep_open) do |out|
          handle_stream(out, protocol_class.new)
        end
      end
    end

    error JSON::ParserError do
      content_type :json
      { error: { message: "Invalid JSON" } }.to_json
    end

    not_found do
      content_type :json
      { error: { message: "Not found" } }.to_json
    end

    private

    def handle_stream(out, protocol)
      body = JSON.parse(@request_body)
      model_id = protocol.model_from(body)

      model_info = LLMProxy.catalog.lookup(model_id)

      unless model_info
        fallback_id = LLMProxy.default_model
        fallback = fallback_id ? LLMProxy.catalog.lookup(fallback_id) : nil
        fallback ||= LLMProxy.catalog.all.first
        if fallback
          @log.warn("  Unknown model: #{model_id}, falling back to #{fallback.id}")
          body["model"] = fallback.id
          model_id = fallback.id
          model_info = fallback
        else
          out << SSE.format({ type: "error", error: { message: "Unknown model: #{model_id}" } })
          out << SSE.format({ type: "response.completed", response: { id: "resp_0", status: "completed", model: "unknown", output: [] } })
          out << "data: [DONE]\n\n"
          out.close
          return
        end
      end

      normalized = protocol.normalize(body)
      msg_count = (normalized[:messages] || []).length
      tool_count = (normalized[:tools] || []).length
      @log.info("  model=#{model_id} (#{model_info.provider}) msgs=#{msg_count} tools=#{tool_count}")
      @log.debug("  system=#{normalized[:system].inspect}")
      @log.debug("  thinking=#{normalized[:thinking].inspect} stream=#{normalized[:stream]} max_tokens=#{normalized[:max_tokens]} temp=#{normalized[:temperature].inspect}")

      is_streaming = normalized[:stream] != false

      unless is_streaming
        chat = build_chat(model_info, normalized)
        chat.complete
        final_msg = chat.messages.last
        usage = token_usage(final_msg)
        @log.info("  Usage: #{usage.inspect}")
        payload = protocol.complete_events(model: model_info.id, usage: usage)
        completed = payload.find { |e| e.is_a?(Hash) && e[:type] == "response.completed" }
        out << (completed || { type: "response.completed", response: { id: "resp_0", status: "completed", model: model_info.id, output: [] } }).to_json
        return
      end

      begin
        chat = build_chat(model_info, normalized)
        chat.before_tool_call { raise ToolCallStop }

        @log.debug("  Starting stream...")
        out << SSE.format(protocol.start_events(model: model_info.id))
        event_count = 1

        chat.complete do |chunk|
          events = protocol.chunk_events(chunk, model: model_info.id)
          unless events.empty?
            out << SSE.format(events)
            event_count += events.length
            if event_count % 50 == 0 && event_count > 0
              @log.debug("  Streamed #{event_count} events...")
            end
          end
        end

        @log.info("  Streamed #{event_count} events total")
        final_msg = chat.messages.last
        usage = token_usage(final_msg)
        @log.info("  Usage: #{usage.inspect}")
        @log.info("  Finish reason: #{final_msg&.tool_call? ? 'tool_calls' : 'stop'}")
        complete_events = protocol.complete_events(model: model_info.id, usage: usage)
        completed = complete_events.find { |e| e.is_a?(Hash) && e[:type] == "response.completed" }
        @log.debug("  complete_events count=#{complete_events.length}")
        @log.debug("  response.completed output items=#{completed&.dig(:response, :output)&.length || 0}") if completed
        out << SSE.format(complete_events)

      rescue ToolCallStop
        @log.info("  Tool call stop (streamed tool calls)")
        final_msg = chat&.messages&.last rescue nil
        usage = token_usage(final_msg)
        @log.info("  Usage: #{usage.inspect}") if usage
        out << SSE.format(protocol.complete_events(model: model_info.id, usage: usage))
      rescue => e
        @log.error("Error: #{e.class}: #{e.message}")
        @log.debug("  #{e.backtrace&.first(5)&.join("\n    ")}")
        out << SSE.format(protocol.error_events(e.message))
        out << SSE.format(protocol.complete_events(model: model_info.id))
      ensure
        out << "data: [DONE]\n\n"
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @_start_time) * 1000).round(1)
        @log.info("  => 200 (#{duration}ms)")
        out.close
      end
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

    def token_usage(msg)
      return nil unless msg&.tokens
      { input: msg.input_tokens, output: msg.output_tokens }.compact
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
