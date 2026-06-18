require "fileutils"
require "securerandom"

module LLMProxy
  module Codex
    RUNTIME_DIR = File.expand_path("../../.codex-shim", __dir__)
    CODEX_CONFIG = File.expand_path("~/.codex/config.toml")
    CODEX_BACKUP = File.join(RUNTIME_DIR, "config.toml.before-llm-proxy")
    MANAGED_BEGIN = "# >>> llm-proxy managed >>>"
    MANAGED_END = "# <<< llm-proxy managed <<<"

    class << self
      def enable(model_slug, config)
        port = config.server[:port] || 8765
        proxy_name = "llm_proxy"
        config_dir = File.dirname(CODEX_CONFIG)
        Dir.mkdir(config_dir) unless Dir.exist?(config_dir)
        Dir.mkdir(RUNTIME_DIR) unless Dir.exist?(RUNTIME_DIR)

        original = File.exist?(CODEX_CONFIG) ? File.read(CODEX_CONFIG) : ""
        if !original.include?(MANAGED_BEGIN) && !File.exist?(CODEX_BACKUP)
          File.write(CODEX_BACKUP, original)
        end

        cleaned = remove_managed_sections(original)
        cleaned = remove_top_level_keys(cleaned, %w[model model_provider])
        cleaned = remove_section(cleaned, "model_providers.llm_proxy")

        token = SecureRandom.hex(32)

        top = <<~TOP
          #{MANAGED_BEGIN}
          model = "#{model_slug}"
          model_provider = "#{proxy_name}"
          #{MANAGED_END}
        TOP

        prov = <<~PROV
          #{MANAGED_BEGIN}
          [model_providers.#{proxy_name}]
          name = "LLM Proxy"
          base_url = "http://127.0.0.1:#{port}/v1"
          wire_api = "responses"
          experimental_bearer_token = "#{token}"
          request_max_retries = 3
          stream_max_retries = 3
          stream_idle_timeout_ms = 600000
          #{MANAGED_END}
        PROV

        File.write(CODEX_CONFIG, top + "\n" + cleaned.lstrip + "\n" + prov)
        puts "✅ Proxy mode enabled — Codex will use #{model_slug} via llm-proxy"
        puts "   Restart Codex for changes to take effect."
      end

      def disable
        unless File.exist?(CODEX_BACKUP)
          unless File.exist?(CODEX_CONFIG)
            puts "No config to restore."
            return
          end
          current = File.read(CODEX_CONFIG)
          restored = remove_managed_sections(current)
          File.write(CODEX_CONFIG, restored.lstrip)
          puts "✅ Proxy mode disabled — Codex is back to native"
          return
        end

        File.write(CODEX_CONFIG, File.read(CODEX_BACKUP))
        FileUtils.rm(CODEX_BACKUP)
        puts "✅ Proxy mode disabled — Codex restored to original config"
      end

      private

      def remove_managed_sections(text)
        while text.include?(MANAGED_BEGIN)
          before, rest = text.split(MANAGED_BEGIN, 2)
          return before unless rest.include?(MANAGED_END)
          _, after = rest.split(MANAGED_END, 2)
          text = before + after
        end
        text
      end

      def remove_top_level_keys(text, keys)
        lines = text.lines
        in_top = true
        out = []
        lines.each do |line|
          in_top = false if line.strip.start_with?("[")
          key = line.split("=", 2).first&.strip
          if in_top && keys.include?(key)
          else
            out << line
          end
        end
        out.join
      end

      def remove_section(text, section)
        header = "[#{section}]"
        skip = false
        lines = text.lines
        out = []
        lines.each do |line|
          st = line.strip
          if st.start_with?("[") && st.end_with?("]")
            skip = (st == header)
            next if skip
          end
          out << line unless skip
        end
        out.join
      end

    end
  end
end
