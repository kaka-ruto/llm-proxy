# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module LLMProxy
  # Integrates llm-proxy with the ZCode desktop app.
  #
  # ZCode speaks the Anthropic Messages protocol (POST /v1/messages), which the
  # proxy already serves. This module adds a custom `source: "custom"` provider
  # entry to ~/.zcode/v2/config.json pointing at the local proxy. Custom/API-key
  # providers skip ZCode's OAuth + entitlement machinery, so the entry stays
  # active and is never remotely disabled. It survives ZCode updates, mirrors
  # the existing LLMProxy::Codex pattern, and is fully reversible via `disable`.
  module ZCode
    MANAGED_MARKER = "llm-proxy"

    class << self
      # Overridable paths so tests can point at a tmpdir instead of the user's
      # real config. Defaults resolve to the user's ~/.zcode/v2/config.json and
      # an in-repo .llm-proxy/ runtime dir for backups.
      def config_file
        File.expand_path(ENV["ZCODE_CONFIG"] || "~/.zcode/v2/config.json")
      end

      def runtime_dir
        File.expand_path(ENV["ZCODE_RUNTIME_DIR"] || "../../.llm-proxy", __dir__)
      end

      def backup_file
        File.join(runtime_dir, "config.json.before-llm-proxy")
      end

      # Public: write a custom provider into ZCode's config pointing at the proxy.
      #
      # model_id  - the catalog model id to highlight as default (String).
      # config    - the LLMProxy::Config (for server port).
      def enable(model_id, config)
        port = config.server[:port] || 8765
        token = SecureRandom.hex(32)

        ensure_dirs

        original = File.exist?(config_file) ? File.read(config_file) : ""
        existing = parse_json(original)

        backup_original_once(existing, original)

        # Re-entrancy: drop any prior managed entry, then (re)add ours.
        providers = existing["provider"] ||= {}
        providers.delete(PROVIDER_KEY)

        entry = build_provider_entry(
          port: port,
          token: token,
          default_model: model_id,
          models: Ask::ModelCatalog.instance.all
        )
        providers[PROVIDER_KEY] = entry

        write_config(existing)

        puts "✅ Proxy mode enabled — ZCode will use #{model_id} via llm-proxy"
        puts "   Provider: \"LLM Proxy\" (#{base_url(port)})"
        puts "   Restart ZCode for the new provider to appear in the model picker."
      end

      # Public: remove the managed provider entry, restoring the original config
      # if a backup exists, otherwise deleting just the managed key in place.
      def disable
        unless File.exist?(config_file)
          puts "No ZCode config to restore."
          return
        end

        if File.exist?(backup_file)
          File.write(config_file, File.read(backup_file))
          chmod_config
          FileUtils.rm(backup_file)
          puts "✅ Proxy mode disabled — ZCode restored to original config"
          return
        end

        existing = parse_json(File.read(config_file))
        providers = existing["provider"]
        removed = providers&.delete(PROVIDER_KEY)
        if removed
          write_config(existing)
          puts "✅ Proxy mode disabled — removed \"LLM Proxy\" provider"
        else
          puts "No llm-proxy provider found in ZCode config."
        end
      end

      # --- Entry construction ------------------------------------------------

      # Public (for tests): build the provider entry hash without writing files.
      def build_provider_entry(port:, token:, default_model:, models:)
        entry = {
          "name" => "LLM Proxy",
          "kind" => "anthropic",
          "source" => "custom",
          "enabled" => true,
          "options" => {
            "baseURL" => base_url(port),
            "apiKey" => token,
            "apiKeyRequired" => true
          },
          "models" => build_models_map(models, default_model)
        }
        entry
      end

      # Public (for tests): build the per-model map from the catalog.
      def build_models_map(models, default_model)
        models.each_with_object({}) do |m, acc|
          acc[m.id] = model_entry(m, highlight: m.id == default_model)
        end
      end

      private

      PROVIDER_KEY = "llm-proxy".freeze

      def ensure_dirs
        cf_dir = File.dirname(config_file)
        FileUtils.mkdir_p(cf_dir)
        FileUtils.mkdir_p(runtime_dir)
        FileUtils.chmod(0700, cf_dir) if File.stat(cf_dir).mode & 0777 != 0700
      end

      # Back up the original config exactly once: only when we're about to add
      # the managed entry for the first time (no prior entry, no prior backup).
      def backup_original_once(existing, original)
        providers = existing["provider"]
        already_managed = providers&.key?(PROVIDER_KEY)
        return if already_managed
        return if File.exist?(backup_file)
        return if original.to_s.strip.empty?

        File.write(backup_file, original)
        File.chmod(0600, backup_file)
      end

      def model_entry(model, highlight:)
        entry = {
          "limit" => {
            "context" => model.context_window,
            "output" => model.max_output_tokens
          },
          "modalities" => {
            "input" => ["text"],
            "output" => ["text"]
          }
        }
        # Vision-capable models accept image input.
        entry["modalities"]["input"] << "image" if model.supports?("vision")

        if model.supports?("reasoning")
          entry["reasoning"] = {
            "enabled" => true,
            "variants" => ["enabled", "off"],
            "defaultVariant" => highlight ? "enabled" : "off"
          }
        end

        entry
      end

      def write_config(hash)
        File.write(config_file, JSON.pretty_generate(hash))
        chmod_config
      end

      def chmod_config
        File.chmod(0600, config_file) if File.exist?(config_file)
      end

      def base_url(port)
        host = ENV["LLM_PROXY_HOST"] || "127.0.0.1"
        "http://#{host}:#{port}"
      end

      def parse_json(text)
        return {} if text.nil? || text.strip.empty?
        JSON.parse(text)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
