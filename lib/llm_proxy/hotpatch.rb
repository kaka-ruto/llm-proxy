# frozen_string_literal: true

# Hotpatch for LLMProxy::Server
# Uses rescue Exception (catches ALL exceptions) instead of rescue => e.
#
# Load from within the running process:
#   bundle exec rdbg -c --pid <pid> -e "load '/abs/path/to/hotpatch.rb'"
# Or via Signal (requires pre-setup):
#   Process.kill('USR1', 34116)  # if handler is set up

module LLMProxy
  module ServerHotpatch
    module_function

    def apply!
      # 1. Suppress RubyLLM noisy DEBUG logging (Faraday connection errors logged internally)
      if defined?(RubyLLM) && RubyLLM.logger
        RubyLLM.logger.level = Logger::WARN
        puts "[hotpatch] RubyLLM.logger.level -> WARN"
      end

      # 2. Redefine safe_send and safe_close with Exception-level rescue
      LLMProxy::Server.define_method(:safe_send) do |out, data|
        out << data
      rescue Exception => e
        @log.warn("Stream write failed: #{e.class}: #{e.message}")
      end

      LLMProxy::Server.define_method(:safe_close) do |out|
        out.close
      rescue Exception => e
        @log.warn("Stream close failed: #{e.class}: #{e.message}")
      end

      puts "[hotpatch] ✓ Applied! Exception-level rescue active"
    end
  end
end

# Auto-apply when loaded inside the running process
if defined?(LLMProxy) && defined?(LLMProxy::Server) && LLMProxy::Server.respond_to?(:define_method)
  LLMProxy::ServerHotpatch.apply!
end
