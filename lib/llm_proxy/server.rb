require "sinatra/base"
require "logger"
require "fileutils"
require "set"
begin; require "ask/instrumentation/tool"; rescue LoadError; end
require "ostruct"
require "securerandom"
require "puma/const"

module LLMProxy
  class Server < Sinatra::Base
    LOG_DIR = File.expand_path("../../logs", __dir__)
    LOG_FILE = File.join(LOG_DIR, "development.log")
    MAX_WEB_SEARCH_ROUNDS = 3

    set :protection, false

    configure do
      FileUtils.mkdir_p(LOG_DIR)
      File.chmod(0700, LOG_DIR)
      _logger = Logger.new(LOG_FILE, "daily")
      File.chmod(0600, LOG_FILE) if File.exist?(LOG_FILE)
      _logger.level = Logger::DEBUG
      _logger.formatter = proc { |severity, datetime, _progname, msg|
        rid = Thread.current[:llm_request_id]
        tag = rid ? "[#{rid}]" : " " * 9
        "[#{datetime.strftime("%Y-%m-%d %H:%M:%S %z")}] #{tag} #{severity}: #{msg}\n"
      }
      set :logger, _logger
      set :server, :puma
      v = $VERBOSE; $VERBOSE = nil
      Puma::Const::WRITE_TIMEOUT = 600
      $VERBOSE = v
      set :server_settings, {}
      set :show_exceptions, false
      set :raise_errors, false
      set :dump_errors, false

      # Clean rotated logs older than 1 day on startup
      Dir[File.join(LOG_DIR, "development.log.*")].each do |f|
        age_seconds = (Time.now - File.mtime(f)).to_i
        File.delete(f) if age_seconds > 86400
      end
    end

    before do
      @request_id = SecureRandom.hex(8)
      Thread.current[:llm_request_id] = @request_id
      @log = settings.logger
      @_errors = []
      @log.info("─" * 60)
      @log.info("#{request.request_method} #{request.path_info}")

      headers = request.env.select { |k, _| k.start_with?("HTTP_") }
      headers = headers.merge("HTTP_AUTHORIZATION" => "[REDACTED]") if headers.key?("HTTP_AUTHORIZATION")
      headers["HTTP_X_OAI_ATTESTATION"] = truncate(headers["HTTP_X_OAI_ATTESTATION"]) if headers["HTTP_X_OAI_ATTESTATION"]
      @log.debug("  Headers: #{headers.to_json}")

      body_str = request.body.read
      request.body.rewind
      safe_body = body_str.gsub(/(?:"apiKey"|"key")\s*:\s*"[^"]+"/, '\1: "[REDACTED]"')
      @log.debug("  Body: #{truncate(safe_body)}")
      @request_body = body_str
      @_streaming = false
      @_request_count = (@_request_count || 0) + 1
      @_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    after do
      unless @_streaming
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @_start_time) * 1000).round(1)
        @log.info("  Completed #{response.status} (#{duration}ms)")
      end
    ensure
      Thread.current[:llm_request_id] = nil
    end

    get "/metrics" do

      content_type "text/plain; version=0.0.4"

      metrics = []

      metrics << '# HELP llm_proxy_tool_calls_total Total tool calls'

      metrics << '# TYPE llm_proxy_tool_calls_total counter'

      metrics << "llm_proxy_tool_calls_total 0"

      metrics << '# HELP llm_proxy_tool_call_duration_ms Tool call duration in ms'

      metrics << '# TYPE llm_proxy_tool_call_duration_ms histogram'

      metrics << '# HELP llm_proxy_requests_total Total proxy requests'

      metrics << '# TYPE llm_proxy_requests_total counter'

      metrics << "llm_proxy_requests_total 0"

      metrics.join("\n") + "\n"

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
        protocol = protocol_class.new
        body = JSON.parse(@request_body)
        requested_model = body["model"] || protocol.model_from(body) || "<unknown>"

        body = resolve_model(body, protocol)
        normalized = protocol.normalize(body, logger: @log)
        model_id = body["model"] || normalized[:model]
        model_info = LLMProxy.catalog.lookup(model_id)
        is_streaming = normalized[:stream] != false

        unless model_info
          content_type :json
          status 400
          next { error: { message: "Unknown model: #{model_id}" } }.to_json
        end

        msg_count = (normalized[:messages] || []).length
        tool_count = (normalized[:tools] || []).length
        resolved = model_id != requested_model ? " (resolved from #{requested_model})" : ""
        @log.info("  model=#{model_id}#{resolved} (#{model_info.provider}) msgs=#{msg_count} tools=#{tool_count}")
        @log.debug("  system=#{normalized[:system] ? truncate(normalized[:system]) : "nil"}")
        @log.debug("  thinking=#{normalized[:thinking].inspect} stream=#{normalized[:stream]} max_tokens=#{normalized[:max_tokens]} temp=#{normalized[:temperature].inspect}")

        chat = build_chat(model_info, normalized)

        if is_streaming
          @_streaming = true
          content_type "text/event-stream"
          headers "Cache-Control" => "no-cache"
          headers "X-Accel-Buffering" => "no"

          stream(:keep_open) do |out|
            begin
              handle_stream(out, protocol, chat, model_info)
            rescue Exception => e
              @_errors << "Fatal stream error: #{e.class}: #{e.message}"
              @log.error("  => #{e.class}: #{e.message}")
              e.backtrace&.first(3)&.each { |line| @log.error("     #{line}") }
              safe_send(out, "data: [DONE]\n\n")
            end
          end
        else
          content_type :json
          handle_nonstreaming(protocol, chat, model_info)
        end
      end
    end

    error JSON::ParserError do
      @_errors << "Invalid JSON in request body"
      @log.error("  Invalid JSON in request body")
      status 400
      content_type :json
      { error: { message: "Invalid JSON" } }.to_json
    end

    not_found do
      @log.warn("  Route not found: #{request.request_method} #{request.path_info}")
      content_type :json
      { error: { message: "Not found" } }.to_json
    end

    private

    # Resolve model, with fallback logic for unknown models.
    def resolve_model(body, protocol)
      model_id = protocol.model_from(body)
      model_info = LLMProxy.catalog.lookup(model_id)

      if model_info
        body
      else
        fallback_id = LLMProxy.default_model
        fallback = fallback_id ? LLMProxy.catalog.lookup(fallback_id) : nil
        fallback ||= LLMProxy.catalog.all.first
        if fallback
          @log.warn("  Unknown model: #{model_id}, falling back to #{fallback.id}")
          body.merge("model" => fallback.id)
        else
          body
        end
      end
    end

    def handle_nonstreaming(protocol, chat, model_info)
      response = chat.ask(nil)

      MAX_WEB_SEARCH_ROUNDS.times do |round|
        log_model_response(response)
        break unless execute_web_search_tools(chat, response, round)

        @log.info("  Web search continuation round #{round + 1}...")
        response = chat.ask(nil)
        log_model_response(response)
      end

      final_msg = response
      log_model_response(final_msg)
      usage = token_usage(final_msg)
      @log.info("  Usage: #{usage.inspect}")
      @log.info("  Finish reason: #{final_msg&.tool_call? ? 'tool_calls' : 'stop'}")

      result_json = format_protocol_response(protocol, model_info, final_msg, usage)
      result_json
    rescue Exception => e
      @_errors << "Non-streaming error: #{e.class}: #{e.message}"
      @log.error("  => #{e.class}: #{e.message}")
      e.backtrace&.first(3)&.each { |line| @log.error("     #{line}") }
      status 500
      { error: { message: e.message } }.to_json
    end

    def log_model_response(msg)
      if msg.tool_call?
        msg.tool_calls.values.each do |tc|
          args = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)
          @log.info("  => tool=#{tc.name} args=#{args}")
        end
      elsif msg.content&.length&.> 0
        @log.info("  => text=#{msg.content}")
      end
    end

    def format_protocol_response(protocol, model_info, msg, usage)
      case protocol
      when Protocols::OpenAICompletions
        content = msg.content.to_s
        choice = { index: 0, message: { role: "assistant", content: content }, finish_reason: "stop" }
        if msg.tool_call?
          calls = msg.tool_calls.values.map { |tc|
            args = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)
            { id: tc.id, type: "function", function: { name: tc.name, arguments: args } }
          }
          choice[:message][:tool_calls] = calls
          choice[:finish_reason] = "tool_calls"
        end
        result = { id: "chatcmpl_#{model_info.id}", object: "chat.completion", model: model_info.id, choices: [choice], created: Time.now.to_i }
        result[:usage] = { prompt_tokens: usage[:input] || 0, completion_tokens: usage[:output] || 0, total_tokens: (usage[:input] || 0) + (usage[:output] || 0) } if usage
        result.to_json
      when Protocols::OpenAIResponses
        output = []
        if msg.tool_call?
          msg.tool_calls.values.each_with_index do |tc, idx|
            args = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)
            output << {
              id: tc.id || "call_#{idx}", type: "function_call",
              status: "completed", call_id: tc.id, name: tc.name, arguments: args
            }
          end
        elsif msg.content&.length&.> 0
          output << {
            id: "msg_0", type: "message", role: "assistant",
            content: [{ type: "output_text", text: msg.content, annotations: [] }]
          }
        end
        result = {
          type: "response.completed",
          response: {
            id: "resp_0", object: "response", status: "completed",
            model: model_info.id, output: output, created_at: Time.now.to_i
          }
        }
        result[:response][:usage] = usage if usage
        result.to_json
      when Protocols::AnthropicMessages
        content = []
        stop_reason = "end_turn"
        if msg.tool_call?
          stop_reason = "tool_use"
          msg.tool_calls.values.each_with_index do |tc, idx|
            args = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)
            content << {
              type: "tool_use", id: tc.id || "toolu_#{idx}",
              name: tc.name, input: args
            }
          end
        elsif msg.content&.length&.> 0
          content << { type: "text", text: msg.content }
        end
        result = {
          type: "message", id: "msg_0", role: "assistant",
          content: content, model: model_info.id,
          stop_reason: stop_reason, stop_sequence: nil,
          usage: usage ? { input_tokens: usage[:input] || 0, output_tokens: usage[:output] || 0 } : { input_tokens: 0, output_tokens: 0 }
        }
        result.to_json
      end
    end

    TRUNCATE_LIMIT = 500

    def truncate(str)
      s = str.to_s
      s.length > TRUNCATE_LIMIT ? "#{s[0, TRUNCATE_LIMIT]}...[#{s.length - TRUNCATE_LIMIT} more bytes]" : s
    end

    def handle_stream(out, protocol, chat, model_info)
      Thread.current[:llm_request_id] = @request_id
      @_stream_dead = false

      begin
        @log.debug("  Starting stream...")
        start_events = protocol.start_events(model: model_info.id)
        safe_send(out, SSE.format(start_events))
        event_count = 1

        response = chat.ask(nil) do |chunk|
          break if @_stream_dead

          if chunk.tool_calls&.any?
            chunk.tool_calls.each do |id, tc|
              @log.info("  Model chunk: tool_call id=#{id || 'nil'} name=#{tc.name} args=#{tc.arguments.inspect}")
            end
          end

          events = protocol.chunk_events(chunk, model: model_info.id)

          unless events.empty?


            safe_send(out, SSE.format(events))
            event_count += events.length
          end
        end

        if @_stream_dead
          @log.warn("  Stream aborted after #{event_count} events (client disconnected)")
          return
        end

        @log.info("  Streamed #{event_count} events total, handling tool calls...")

        MAX_WEB_SEARCH_ROUNDS.times do |round|
          log_model_response(response)
          break unless execute_web_search_tools(chat, response, round)

          @log.info("  Web search continuation round #{round + 1}...")
          response = chat.ask(nil) do |chunk|
            break if @_stream_dead
            events = protocol.chunk_events(chunk, model: model_info.id)
            safe_send(out, SSE.format(events)) unless events.empty?
            event_count += events.length unless events.empty?
          end

          break if @_stream_dead
        end

        protocol.cleanup_accumulated_tool_calls(exclude_names: %w[web_search])
        final_msg = response
        log_model_response(final_msg)
        usage = token_usage(final_msg)
        @log.info("  Usage: #{usage.inspect}")
        @log.info("  Finish reason: #{final_msg&.tool_call? ? 'tool_calls' : 'stop'}")
        complete_events = protocol.complete_events(model: model_info.id, usage: usage)
        safe_send(out, SSE.format(complete_events))

      rescue ToolCallStop
        final_msg = response
        log_model_response(final_msg)
        usage = token_usage(final_msg)
        @log.info("  Usage: #{usage.inspect}")
        @log.info("  Finish reason: #{final_msg&.tool_call? ? 'tool_calls' : 'stop'}")
        tool_calls_info = final_msg&.tool_call? ? final_msg.tool_calls.values.map { |tc| { id: tc.id, name: tc.name } } : []
        @log.info("  Tool call stop: #{tool_calls_info}")
        protocol.cleanup_accumulated_tool_calls(exclude_names: %w[web_search])
        complete_events = protocol.complete_events(model: model_info.id, usage: usage)
        safe_send(out, SSE.format(complete_events))
      rescue Exception => e
        @_errors << "Streaming error: #{e.class}: #{e.message}"
        @log.error("  => #{e.class}: #{e.message}")
        e.backtrace&.first(3)&.each { |line| @log.error("     #{line}") }
        error_events = protocol.error_events(e.message)
        safe_send(out, SSE.format(error_events))
        complete_events = protocol.complete_events(model: model_info.id)
        safe_send(out, SSE.format(complete_events))
      ensure
        safe_send(out, "data: [DONE]\n\n")
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @_start_time) * 1000).round(1)
        status_tag = @_errors.any? ? "500" : "200"
        @log.info("  Completed #{status_tag} (#{duration}ms) streamed=#{@_stream_dead ? 'aborted' : 'ok'}")
        safe_close(out)
      end
    end

    def build_chat(model_info, normalized)
      # Inject model identity so the model knows who it is
      identity = "You are running as model: #{model_info.id} (provider: #{model_info.provider}). " \
                  "You have access to the web_search tool for web lookups and the apply_patch tool for file editing."
      if normalized[:system]
        normalized[:system] = "#{identity}\n\n#{normalized[:system]}"
      else
        normalized[:system] = identity
      end
      # Register the model in Ask::ModelCatalog so Chat can resolve provider
      register_proxy_model(model_info)

      # Auto-inject built-in tools so every client gets them as native tools.
      builtin_tools = [
        {
          name: "web_search",
          description: "Search the web for current information. Use this to get up-to-date results, recent events, or facts that may have changed.",
          parameters: {
            type: "object",
            properties: {
              query: { type: "string", description: "The search query" }
            },
            required: ["query"]
          }
        },
        {
          name: "apply_patch",
          description: "Edit files using a unified diff format. " \
            "Wrap all changes in a \"*** Begin Patch\" / \"*** End Patch\" envelope. " \
            "Each file section starts with a header: " \
            "\"*** Add File: <path>\" for new files, " \
            "\"*** Update File: <path>\" for changes, or " \
            "\"*** Delete File: <path>\" for removals. " \
            "Prefix new lines with +.",
          parameters: {
            type: "object",
            properties: {
              patchText: { type: "string", description: "The full patch text describing all file changes" }
            },
            required: ["patchText"]
          }
        }
      ]

      existing_names = normalized[:tools] ? Set.new(normalized[:tools].map { |t| t[:name] }) : Set.new
      builtin_tools.each do |tool|
        unless existing_names.include?(tool[:name])
          normalized[:tools] = (normalized[:tools] || []) + [tool]
          @log.info("  Auto-injected #{tool[:name]} tool")
        end
      end

      # Build dynamic tools from request
      tools = (normalized[:tools] || []).filter_map do |t|
        if t[:name].nil? || t[:name].strip.empty?
          @log.warn("Skipping tool definition with missing or empty name")
          next
        end
        build_dynamic_tool(t[:name], t[:description], t[:parameters])
      end

      chat = Ask::Agent::Chat.new(
        model: model_info.id,
        tools: tools,
        temperature: normalized[:temperature]
      )

      chat.with_instructions(normalized[:system]) if normalized[:system]

      # Forward tool_choice and parallel_tool_calls to provider
      extra_params = {}
      extra_params[:tool_choice] = normalized[:tool_choice] if normalized.key?(:tool_choice) && !normalized[:tool_choice].nil?
      extra_params[:parallel_tool_calls] = normalized[:parallel_tool_calls] if normalized.key?(:parallel_tool_calls) && !normalized[:parallel_tool_calls].nil?
      chat.with_params(**extra_params) unless extra_params.empty?

      pending_thinking = nil
      buffer = nil

      fetch_key = ->(h, *keys) {
        keys.each { |k| v = h[k]; return v if v }
        nil
      }

      flush_buffer = lambda do
        return unless buffer
        tc_hash = {}
        buffer[:calls].each_with_index do |tc, i|
          fn = fetch_key.call(tc, :function, "function") || tc
          name = fetch_key.call(fn, :name, "name") || ""
          call_id = fetch_key.call(tc, :id, "id") || "call_#{i}"
          raw_args = fetch_key.call(fn, :arguments, "arguments")
          args = parse_tool_args(raw_args)
          tc_hash[call_id] = OpenStruct.new(id: call_id, name: name, arguments: args)
        end
        chat.add_message(role: :assistant, content: nil, tool_calls: tc_hash)
        @_pending_tool_call_ids ||= Set.new
        tc_hash.each_key { |id| @_pending_tool_call_ids << id }
        buffer = nil
      end

      (normalized[:messages] || []).each do |msg|
        role = msg[:role].to_s.to_sym

        if msg[:tool_calls] || (msg[:content].nil? && role == :assistant && msg.key?(:tool_calls))
          buffer ||= { calls: [], thinking: pending_thinking }
          pending_thinking = nil
          (msg[:tool_calls] || []).each { |tc| buffer[:calls] << tc }
        else
          flush_buffer.call
          if role == :tool
            call_id = msg[:tool_call_id]
            match = chat.messages.reverse.find { |m|
              m.role == :assistant && m.respond_to?(:tool_calls) && m.tool_calls.is_a?(Hash) && m.tool_calls.key?(call_id)
            }
            if match
              chat.add_message(role: :tool, content: msg[:content] || "", tool_call_id: call_id)
            elsif @_pending_tool_call_ids&.include?(call_id)
              chat.add_message(role: :tool, content: msg[:content] || "", tool_call_id: call_id)
              @_pending_tool_call_ids.delete(call_id)
            else
              chat.add_message(role: :user, content: "> Output: #{msg[:content].to_s.strip}")
            end
          elsif msg[:content]
            chat.add_message(role: role, content: msg[:content])
          elsif role == :assistant && msg[:summary]
            pending_thinking = msg[:summary].map { |s| s.is_a?(Hash) ? (s["text"] || s[:text]) : s.to_s }.join
          end
        end
      end
      flush_buffer.call

      chat
    end

    # Register a model from the proxy's catalog into Ask::ModelCatalog so
    # Ask::Agent::Chat can resolve the correct provider.
    def register_proxy_model(model_info)
      return if @_registered_models&.include?(model_info.id)
      @_registered_models ||= Set.new
      @_registered_models << model_info.id

      Ask::ModelCatalog.instance.register(
        Ask::ModelInfo.new(
          id: model_info.id,
          provider: model_info.provider,
          context_window: model_info.context_window
        )
      )
    end

    def parse_tool_args(args)
      return {} if args.nil? || args.empty?
      return args if args.is_a?(Hash)
      JSON.parse(args) rescue {}
    end

    def execute_web_search_tools(chat, response, log_round = 0)
      return false unless response.tool_call?

      web_search_calls = response.tool_calls.select { |_id, tc| tc.name == "web_search" }
      return false if web_search_calls.empty?

      @log.info("  Executing #{web_search_calls.length} web_search call(s)...") if log_round == 0

      web_search_calls.each do |id, tc|
        args = tc.arguments
        args = JSON.parse(args) if args.is_a?(String)
        query = args["query"] || args[:query]
        result = Ask::Tools::WebSearch.new.execute(query: query)
        chat.add_message(role: :tool, content: result.to_s, tool_call_id: id)
        @log.info("  web_search[#{id}]: #{truncate(result.to_s)}")
      end

      true
    end

    def build_stream_complete_event(protocol, model_info, msg, usage)
      case protocol
      when Protocols::OpenAICompletions
        choice = { index: 0, message: { role: "assistant", content: msg.content.to_s }, finish_reason: "stop" }
        if msg.tool_call?
          calls = msg.tool_calls.values.map { |tc|
            args = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)
            { id: tc.id, type: "function", function: { name: tc.name, arguments: args } }
          }
          choice[:message][:tool_calls] = calls
          choice[:finish_reason] = "tool_calls"
        end
        result = { id: "chatcmpl_#{model_info.id}", object: "chat.completion", model: model_info.id, choices: [choice], created: Time.now.to_i }
        result[:usage] = usage if usage
        [result]
      when Protocols::OpenAIResponses
        output = []
        if msg.tool_call?
          msg.tool_calls.values.each_with_index do |tc, idx|
            args = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)
            output << { id: tc.id || "call_#{idx}", type: "function_call",
                        status: "completed", call_id: tc.id, name: tc.name, arguments: args }
          end
        elsif msg.content&.length&.> 0
          output << { id: "msg_0", type: "message", role: "assistant",
                      content: [{ type: "output_text", text: msg.content, annotations: [] }] }
        end
        result = { type: "response.completed",
                   response: { id: "resp_0", object: "response", status: "completed",
                               model: model_info.id, output: output, created_at: Time.now.to_i } }
        result[:response][:usage] = usage if usage
        [result]
      when Protocols::AnthropicMessages
        stop_reason = msg.tool_call? ? "tool_use" : "end_turn"
        usage_out = usage ? { input_tokens: usage[:input] || 0, output_tokens: usage[:output] || 0 } : { input_tokens: 0, output_tokens: 0 }
        [
          { type: "message_delta", delta: { stop_reason: stop_reason, stop_sequence: nil }, usage: usage_out },
          { type: "message_stop" }
        ]
      end
    end

    def token_usage(msg)
      return nil unless msg
      if msg.respond_to?(:input_tokens)
        { input: msg.input_tokens, output: msg.output_tokens }.compact
      elsif msg.respond_to?(:content) && msg.respond_to?(:tool_calls)
        # ResponseMessage from Ask::Agent::Chat doesn't have token tracking
        nil
      end
    end

    def build_dynamic_tool(name, description, parameters)
      schema = (parameters || {}).transform_keys(&:to_sym)
      schema[:type] ||= "object"

      klass = Class.new(Ask::Tool) do
        description(description || "")
        params(schema) if schema[:properties]&.any? || schema[:type]
        define_method(:execute) { |**| raise LLMProxy::ToolCallStop }
      end
      klass.define_method(:name) { name }
      klass.new
    end

    def safe_send(out, data)
      return if @_stream_dead
      out << data
    rescue Exception => e
      @_stream_dead = true
      @_errors << "Write failed: #{e.class}: #{e.message}"
      @log.warn("  Write failed (client disconnected?): #{e.class}: #{e.message}")
    end

    def safe_close(out)
      out.close
    rescue Exception => e
      @log.warn("  Close failed: #{e.class}: #{e.message}")
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
