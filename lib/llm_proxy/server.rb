require "sinatra/base"
require "logger"
require "fileutils"
require "set"

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

      # Delete rotated logs left from previous sessions
      Dir[File.join(LOG_DIR, "development.log.*")].each { |f| File.delete(f) }
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

      # Delete rotated logs (handles cross-midnight — @log.info above may have
      # triggered daily rotation, leaving a stale development.log.YYYYMMDD)
      Dir[File.join(LOG_DIR, "development.log.*")].each { |f| File.delete(f) }
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

    post "/api/goals" do
      content_type :json
      headers "Access-Control-Allow-Origin" => "*"
      headers "Access-Control-Allow-Methods" => "POST, GET, OPTIONS"
      headers "Access-Control-Allow-Headers" => "Content-Type"

      body = JSON.parse(@request_body)
      operation = body["operation"]

      case operation
      when "set"
        goal = LLMProxy::Goals.set(
          thread_id: body["threadId"] || body["thread_id"],
          objective: body["objective"],
          status: body["status"]
        )
        { goal: goal }.to_json
      when "set_status"
        goal = LLMProxy::Goals.set_status(
          thread_id: body["threadId"] || body["thread_id"],
          status: body["status"]
        )
        { goal: goal }.to_json
      when "clear"
        LLMProxy::Goals.clear(body["threadId"] || body["thread_id"])
        { success: true }.to_json
      else
        status 400
        { error: "Unknown operation: #{operation}" }.to_json
      end
    end

    options "/api/goals" do
      headers "Access-Control-Allow-Origin" => "*"
      headers "Access-Control-Allow-Methods" => "POST, GET, OPTIONS"
      headers "Access-Control-Allow-Headers" => "Content-Type"
      200
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
          # Safety net: prevent any unhandled exception from escaping the
          # stream block and crashing the Puma thread pool. This catches
          # errors that might slip past handle_stream's own rescue when
          # writing to an already-closed stream.
          begin
            handle_stream(out, protocol_class.new)
          rescue => e
            @log.error("Fatal stream error: #{e.class}: #{e.message}")
            @log.debug("  #{e.backtrace&.first(3)&.join("\n    ")}")
            safe_send(out, "data: [DONE]\n\n")
          end
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
          safe_send(out, SSE.format({ type: "error", error: { message: "Unknown model: #{model_id}" } }))
          safe_send(out, SSE.format({ type: "response.completed", response: { id: "resp_0", status: "completed", model: "unknown", output: [] } }))
          safe_send(out, "data: [DONE]\n\n")
          safe_close(out)
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
        begin
          chat = build_chat(model_info, normalized)
          chat.before_tool_call { raise ToolCallStop }
          begin
            chat.complete
          rescue ToolCallStop
            # Tool call was made in non-streaming — return it as response.completed
          end
          final_msg = chat.messages.last
          usage = token_usage(final_msg)
          @log.info("  Usage: #{usage.inspect}")
          payload = protocol.complete_events(model: model_info.id, usage: usage)
          completed = payload.find { |e| e.is_a?(Hash) && e[:type] == "response.completed" }
          safe_send(out, (completed || { type: "response.completed", response: { id: "resp_0", status: "completed", model: model_info.id, output: [] } }).to_json)
        rescue => e
          @log.error("Non-streaming error: #{e.class}: #{e.message}")
          @log.debug("  #{e.backtrace&.first(5)&.join("\n    ")}")
          safe_send(out, { error: { message: e.message, type: "connection_error" } }.to_json)
        end
        return
      end

      begin
        chat = build_chat(model_info, normalized)
        chat.before_tool_call { raise ToolCallStop }

        @log.debug("  Starting stream...")
        safe_send(out, SSE.format(protocol.start_events(model: model_info.id)))
        event_count = 1

        chat.complete do |chunk|
          events = protocol.chunk_events(chunk, model: model_info.id)
          unless events.empty?
            safe_send(out, SSE.format(events))
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
        safe_send(out, SSE.format(complete_events))

      rescue ToolCallStop
        final_msg = chat&.messages&.last rescue nil
        tool_calls_info = final_msg&.tool_call? ? final_msg.tool_calls.values.map { |tc| { id: tc.id, name: tc.name } } : []
        @log.info("  Tool call stop: #{tool_calls_info}")
        usage = token_usage(final_msg)
        @log.info("  Usage: #{usage.inspect}") if usage
        safe_send(out, SSE.format(protocol.complete_events(model: model_info.id, usage: usage)))
      rescue => e
        @log.error("Streaming error: #{e.class}: #{e.message}")
        @log.debug("  #{e.backtrace&.first(5)&.join("\n    ")}")
        safe_send(out, SSE.format(protocol.error_events(e.message)))
        safe_send(out, SSE.format(protocol.complete_events(model: model_info.id)))
      ensure
        safe_send(out, "data: [DONE]\n\n")
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @_start_time) * 1000).round(1)
        @log.info("  => 200 (#{duration}ms)")
        safe_close(out)
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

      pending_thinking = nil
      buffer = nil  # accumulates consecutive function_call items

      flush_buffer = lambda do
        return unless buffer
        tc_hash = buffer[:calls].to_h do |tc|
          fn = tc[:function] || tc
          name = fn[:name] || tc[:name] || ""
          call_id = tc[:id] || "call_#{buffer[:calls].index(tc)}"
          args = parse_tool_args(fn[:arguments] || tc[:arguments])
          [call_id, RubyLLM::ToolCall.new(id: call_id, name: name, arguments: args)]
        end
        chat.add_message(role: :assistant, content: nil, tool_calls: tc_hash,
                          thinking: RubyLLM::Thinking.new(text: buffer[:thinking] || ""))
        buffer = nil
      end

      (normalized[:messages] || []).each do |msg|
        role = msg[:role].to_s.to_sym

        if msg[:tool_calls]
          if buffer.nil?
            buffer = { calls: [], thinking: pending_thinking }
            pending_thinking = nil
          end
          buffer[:calls].concat(msg[:tool_calls])
        else
          flush_buffer.call
          if role == :tool
            call_id = msg[:tool_call_id]
            match = chat.messages.reverse.find { |m| m.role == :assistant && m.tool_call? && m.tool_calls.key?(call_id) }
            if match
              chat.add_message(role: :tool, content: msg[:content] || "", tool_call_id: call_id)
            else
              chat.add_message(role: :user, content: "> Output: #{msg[:content].to_s.strip}")
            end
          elsif msg[:content]
            attrs = { role: role, content: msg[:content] }
            chat.add_message(attrs)
          elsif role == :assistant && msg[:summary]
            pending_thinking = msg[:summary].map { |s| s.is_a?(Hash) ? (s["text"] || s[:text]) : s.to_s }.join
          end
        end
      end
      flush_buffer.call

      chat
    end

    def parse_tool_args(args)
      return {} if args.nil? || args.empty?
      return args if args.is_a?(Hash)
      JSON.parse(args) rescue {}
    end

    def token_usage(msg)
      return nil unless msg&.tokens
      { input: msg.input_tokens, output: msg.output_tokens }.compact
    end

    def build_dynamic_tool(name, description, parameters)
      schema = (parameters || {}).transform_keys(&:to_sym)
      schema[:type] ||= "object"
      schema[:properties] ||= {}
      schema[:additionalProperties] = false unless schema.key?(:additionalProperties)

      klass = Class.new(RubyLLM::Tool) do
        description(description || "")
        define_method(:execute) { |**| raise LLMProxy::ToolCallStop }
      end
      klass.define_method(:name) { name }
      sd = RubyLLM::Tool::SchemaDefinition.new(schema: schema)
      klass.instance_variable_set(:@params_schema_definition, sd)
      klass
    end

    # Safely write to the stream, swallowing errors if the client already
    # disconnected or the stream is closed. Prevents unhandled exceptions
    # from propagating out of handle_stream and crashing the Puma thread.
    def safe_send(out, data)
      out << data
    rescue => e
      @log.warn("Stream write failed (client disconnected?): #{e.class}: #{e.message}")
    end

    # Safely close the stream, swallowing errors if already closed.
    def safe_close(out)
      out.close
    rescue => e
      @log.warn("Stream close failed: #{e.class}: #{e.message}")
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
