require_relative "test_helper"
require "tmpdir"
require "fileutils"

describe LLMProxy::ZCode do
  # A small, deterministic catalog for entry-construction assertions.
  def build_catalog(models)
    LLMProxy::ModelCatalog.new(
      LLMProxy::Config.new(server: { port: 8765 }, models: models)
    )
  end

  def model(id, provider: "deepseek", context_window: 1000, max_tokens: 100,
            capabilities: [])
    LLMProxy::ModelConfig.new(
      id: id, provider: provider, display_name: id,
      context_window: context_window, max_tokens: max_tokens,
      capabilities: capabilities
    )
  end

  # ----- Provider entry construction (no file I/O) -----

  describe "build_provider_entry" do
    it "builds a custom anthropic provider pointing at the proxy" do
      entry = LLMProxy::ZCode.build_provider_entry(
        port: 8765, token: "tok123",
        default_model: "deepseek-v4-flash",
        models: [model("deepseek-v4-flash")]
      )

      _(entry["name"]).must_equal "LLM Proxy"
      _(entry["kind"]).must_equal "anthropic"
      _(entry["source"]).must_equal "custom"
      _(entry["enabled"]).must_equal true
      _(entry["options"]["baseURL"]).must_equal "http://127.0.0.1:8765"
      _(entry["options"]["apiKey"]).must_equal "tok123"
      _(entry["options"]["apiKeyRequired"]).must_equal true
    end

    it "uses the configured port and respects LLM_PROXY_HOST" do
      prev_host = ENV["LLM_PROXY_HOST"]
      ENV["LLM_PROXY_HOST"] = "localhost"
      entry = LLMProxy::ZCode.build_provider_entry(
        port: 9999, token: "t", default_model: "m", models: []
      )
      _(entry["options"]["baseURL"]).must_equal "http://localhost:9999"
    ensure
      ENV["LLM_PROXY_HOST"] = prev_host
    end

    it "includes every catalog model in the models map" do
      models = [model("deepseek-v4-flash"), model("kimi-k2.6"), model("gpt-4o")]
      entry = LLMProxy::ZCode.build_provider_entry(
        port: 8765, token: "t", default_model: "deepseek-v4-flash", models: models
      )
      _(entry["models"].keys).must_equal ["deepseek-v4-flash", "kimi-k2.6", "gpt-4o"]
    end
  end

  describe "build_models_map" do
    it "carries context window and max_tokens into limit" do
      map = LLMProxy::ZCode.build_models_map(
        [model("m1", context_window: 200_000, max_tokens: 8192)],
        "m1"
      )
      _(map["m1"]["limit"]["context"]).must_equal 200_000
      _(map["m1"]["limit"]["output"]).must_equal 8192
    end

    it "sets text-only modalities by default" do
      map = LLMProxy::ZCode.build_models_map([model("m1")], "m1")
      _(map["m1"]["modalities"]["input"]).must_equal ["text"]
      _(map["m1"]["modalities"]["output"]).must_equal ["text"]
    end

    it "adds image input modality for vision-capable models" do
      map = LLMProxy::ZCode.build_models_map(
        [model("gpt-4o", capabilities: ["vision"])], "gpt-4o"
      )
      _(map["gpt-4o"]["modalities"]["input"]).must_include "image"
    end

    it "enables reasoning for reasoning-capable models" do
      map = LLMProxy::ZCode.build_models_map(
        [model("kimi", capabilities: ["reasoning"])], "kimi"
      )
      _(map["kimi"]["reasoning"]["enabled"]).must_equal true
      _(map["kimi"]["reasoning"]["variants"]).must_equal ["enabled", "off"]
    end

    it "defaults the highlighted model's reasoning to enabled, others to off" do
      models = [
        model("default", capabilities: ["reasoning"]),
        model("other", capabilities: ["reasoning"])
      ]
      map = LLMProxy::ZCode.build_models_map(models, "default")
      _(map["default"]["reasoning"]["defaultVariant"]).must_equal "enabled"
      _(map["other"]["reasoning"]["defaultVariant"]).must_equal "off"
    end
  end

  # ----- Full enable/disable file round-trips (real file I/O in a tmpdir) -----

  describe "enable/disable against a real config file" do
    before do
      @tmp = Dir.mktmpdir("zcode-test")
      @config_file = File.join(@tmp, "v2", "config.json")
      @runtime_dir = File.join(@tmp, "shim")

      # Redirect the module to the tmpdir via the ENV hooks.
      @prev_cfg = ENV["ZCODE_CONFIG"]
      @prev_rt = ENV["ZCODE_RUNTIME_DIR"]
      ENV["ZCODE_CONFIG"] = @config_file
      ENV["ZCODE_RUNTIME_DIR"] = @runtime_dir

      @cfg = LLMProxy::Config.new(
        server: { port: 8765 },
        models: [model("deepseek-v4-flash", capabilities: ["reasoning", "tools"])]
      )
    end

    after do
      ENV["ZCODE_CONFIG"] = @prev_cfg
      ENV["ZCODE_RUNTIME_DIR"] = @prev_rt
      FileUtils.rm_rf(@tmp)
    end

    def read_config
      JSON.parse(File.read(@config_file))
    end

    it "creates the config dir and config file when none exists" do
      refute File.exist?(@config_file)
      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      assert File.exist?(@config_file)
      assert File.directory?(File.dirname(@config_file))
    end

    it "writes a valid provider entry into config.json" do
      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      provider = read_config["provider"]["llm-proxy"]

      _(provider["kind"]).must_equal "anthropic"
      _(provider["source"]).must_equal "custom"
      _(provider["enabled"]).must_equal true
      _(provider["options"]["baseURL"]).must_equal "http://127.0.0.1:8765"
      _(provider["models"]).must_include "deepseek-v4-flash"
    end

    it "creates a backup of the original config on first enable" do
      FileUtils.mkdir_p(File.dirname(@config_file))
      original = { "provider" => { "builtin:zai" => { "name" => "Z.ai" } },
                   "other" => "keep-me" }
      File.write(@config_file, JSON.generate(original))

      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)

      assert File.exist?(LLMProxy::ZCode.backup_file)
      backed_up = JSON.parse(File.read(LLMProxy::ZCode.backup_file))
      _(backed_up["other"]).must_equal "keep-me"
      refute backed_up["provider"].key?("llm-proxy")
    end

    it "does not overwrite an existing backup on a second enable" do
      FileUtils.mkdir_p(File.dirname(@config_file))
      File.write(@config_file, JSON.generate({ "version" => 1 }))

      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      first_backup = File.read(LLMProxy::ZCode.backup_file)

      # User makes a change between enables.
      sleep 0.01
      File.write(@config_file, JSON.generate({ "version" => 2 }))
      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)

      _(File.read(LLMProxy::ZCode.backup_file)).must_equal first_backup
    end

    it "is idempotent: re-enabling replaces the provider, never duplicates it" do
      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      first_token = read_config["provider"]["llm-proxy"]["options"]["apiKey"]

      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      second_token = read_config["provider"]["llm-proxy"]["options"]["apiKey"]

      # New token each enable (matches Codex behavior).
      refute_equal first_token, second_token
      provider_keys = read_config["provider"].keys
      _(provider_keys.count { |k| k == "llm-proxy" }).must_equal 1
    end

    it "preserves other providers and top-level keys when enabling" do
      FileUtils.mkdir_p(File.dirname(@config_file))
      original = {
        "provider" => { "builtin:zai" => { "name" => "Z.ai", "enabled" => true } },
        "ui" => { "theme" => "dark" }
      }
      File.write(@config_file, JSON.generate(original))

      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)

      cfg = read_config
      _(cfg["provider"]["builtin:zai"]["name"]).must_equal "Z.ai"
      _(cfg["ui"]["theme"]).must_equal "dark"
      _(cfg["provider"]).must_include "llm-proxy"
    end

    it "disable restores the original config from backup byte-for-byte" do
      FileUtils.mkdir_p(File.dirname(@config_file))
      original_json = JSON.pretty_generate({ "provider" => { "x" => { "n" => 1 } } })
      File.write(@config_file, original_json)

      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      LLMProxy::ZCode.disable

      _(File.read(@config_file)).must_equal original_json
      refute File.exist?(LLMProxy::ZCode.backup_file)
    end

    it "disable without backup removes only the managed provider key" do
      FileUtils.mkdir_p(File.dirname(@config_file))
      File.write(@config_file, JSON.generate({ "provider" => { "x" => {} } }))

      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      # Simulate backup loss (e.g. user deleted it).
      FileUtils.rm(LLMProxy::ZCode.backup_file)

      LLMProxy::ZCode.disable

      cfg = read_config
      refute cfg["provider"].key?("llm-proxy")
      # The other provider we seeded stays intact.
      _(cfg["provider"]).must_include "x"
    end

    it "disable reports nothing to remove when no managed provider exists" do
      FileUtils.mkdir_p(File.dirname(@config_file))
      File.write(@config_file, JSON.generate({ "provider" => { "x" => {} } }))

      # No backup, no managed key -> no-op, file unchanged.
      before = File.read(@config_file)
      LLMProxy::ZCode.disable
      _(File.read(@config_file)).must_equal before
    end

    it "disable says no config when the config file is absent" do
      ENV["ZCODE_CONFIG"] = File.join(@tmp, "nope", "missing.json")
      # Must not raise.
      LLMProxy::ZCode.disable
      refute File.exist?(ENV["ZCODE_CONFIG"])
    end

    it "writes valid JSON that round-trips through JSON.parse" do
      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      parsed = JSON.parse(File.read(@config_file))
      _(parsed).must_be_kind_of Hash
    end

    it "sets restrictive permissions (0600) on the config and backup" do
      # Seed a real original so a backup is actually created.
      FileUtils.mkdir_p(File.dirname(@config_file))
      File.write(@config_file, JSON.generate({ "provider" => { "x" => {} } }))

      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      cfg_mode = File.stat(@config_file).mode & 0777
      bak_mode = File.stat(LLMProxy::ZCode.backup_file).mode & 0777
      _(cfg_mode & 0077).must_equal 0
      _(bak_mode & 0077).must_equal 0
    end

    it "recovers gracefully when the existing config is malformed JSON" do
      FileUtils.mkdir_p(File.dirname(@config_file))
      File.write(@config_file, "{ this is not json")

      # Must not raise; starts fresh rather than crashing.
      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      _(read_config["provider"]).must_include "llm-proxy"
    end

    it "handles an empty (whitespace-only) config file" do
      FileUtils.mkdir_p(File.dirname(@config_file))
      File.write(@config_file, "   \n  ")

      LLMProxy::ZCode.enable("deepseek-v4-flash", @cfg)
      # No backup created for an empty original (nothing meaningful to save),
      # but the provider is still written.
      _(read_config["provider"]).must_include "llm-proxy"
    end
  end
end
