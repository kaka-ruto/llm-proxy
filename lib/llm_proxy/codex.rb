require "open3"
require "fileutils"
require "digest"
require "zlib"
require "securerandom"

module LLMProxy
  module Codex
    RUNTIME_DIR = File.expand_path("../../.codex-shim", __dir__)
    APP_ASAR = "/Applications/Codex.app/Contents/Resources/app.asar"

    BACKUP_DIR = File.join(RUNTIME_DIR, "backups")
    CODEX_CONFIG = File.expand_path("~/.codex/config.toml")
    CODEX_BACKUP = File.join(RUNTIME_DIR, "config.toml.before-llm-proxy")
    MANAGED_BEGIN = "# >>> llm-proxy managed >>>"
    MANAGED_END = "# <<< llm-proxy managed <<<"

    class << self
      def backup
        version = codex_version
        backup_path = File.join(BACKUP_DIR, version[:build])
        FileUtils.mkdir_p(backup_path)

        dest = File.join(backup_path, "app.asar.gz")
        unless File.exist?(dest)
          data = File.read(APP_ASAR, mode: "rb")
          Zlib::GzipWriter.open(dest) { |gz| gz.write(data) }
          File.write(File.join(backup_path, "version.txt"), "#{version[:short]} (build #{version[:build]})\n")
          File.write(File.join(backup_path, "asar.sha256"), Digest::SHA256.hexdigest(data) + "\n")
          size_mb = (data.bytesize.to_f / 1024 / 1024).round(1)
          puts "✅ Backed up Codex #{version[:short]} (#{version[:build]}) — #{size_mb}MB"
        else
          puts "ℹ️  Codex #{version[:short]} (#{version[:build]}) already backed up"
        end
        version
      end

      def restore(build: nil)
        backups = list_backups
        if backups.empty?
          puts "No backups found."
          return
        end

        target = if build
          backups.find { |b| b[:build] == build }
        else
          backups.last
        end

        unless target
          puts "No backup found for build #{build}. Available:"
          backups.each { |b| puts "  #{b[:short]} (build #{b[:build]})" }
          return
        end

        asar_gz = File.join(target[:path], "app.asar.gz")
        unless File.exist?(asar_gz)
          puts "Backup file missing: #{asar_gz}"
          return
        end

        data = Zlib::GzipReader.open(asar_gz) { |gz| gz.read }
        File.write(APP_ASAR, data, mode: "wb")
        system("codesign", "--force", "--deep", "--sign", "-", "/Applications/Codex.app")
        size_mb = (data.bytesize.to_f / 1024 / 1024).round(1)
        puts "✅ Restored Codex #{target[:short]} (build #{target[:build]}) — #{size_mb}MB"
        puts "   Quit and reopen Codex."
      end

      def list_backups
        return [] unless Dir.exist?(BACKUP_DIR)
        Dir.entries(BACKUP_DIR).filter_map do |entry|
          path = File.join(BACKUP_DIR, entry)
          next unless File.directory?(path) && entry.match?(/\A\d+\z/)
          version_file = File.join(path, "version.txt")
          version = File.exist?(version_file) ? File.read(version_file).strip : "unknown"
          { build: entry, short: version.split("(").first&.strip || version, path: path }
        end.sort_by { |b| b[:build].to_i }
      end


      def codex_version
        plist = "/Applications/Codex.app/Contents/Info.plist"
        short = `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "#{plist}" 2>/dev/null`.strip
        build = `/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "#{plist}" 2>/dev/null`.strip
        { short: short, build: build }
      end

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
