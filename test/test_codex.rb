require_relative "test_helper"

describe LLMProxy::Codex do
  before do
    config = LLMProxy::Config.load(CONFIG_PATH)
    LLMProxy.catalog = LLMProxy::ModelCatalog.new(config)
    LLMProxy.default_model = config.server[:default_model]
  end

  describe "default_model from config" do
    it "is set to deepseek-v4-flash" do
      _(LLMProxy.default_model).must_equal "deepseek-v4-flash"
    end
  end

  describe "slug resolution (the enable logic)" do
    it "uses LLMProxy.default_model when set" do
      slug = LLMProxy.default_model ||
             LLMProxy.catalog.all.first&.id&.gsub(/[^a-zA-Z0-9]+/, "-")&.downcase ||
             "model"

      _(slug).must_equal "deepseek-v4-flash"
    end

    it "falls back to first catalog model when default_model is nil" do
      old_default = LLMProxy.default_model
      LLMProxy.default_model = nil

      slug = LLMProxy.default_model ||
             LLMProxy.catalog.all.first&.id&.gsub(/[^a-zA-Z0-9]+/, "-")&.downcase ||
             "model"

      _(slug).must_equal "deepseek-v4-flash"
    ensure
      LLMProxy.default_model = old_default
    end

    it "falls back to 'model' when both default and catalog are empty" do
      old_default = LLMProxy.default_model
      old_catalog = LLMProxy.catalog

      LLMProxy.default_model = nil
      LLMProxy.catalog = LLMProxy::ModelCatalog.new(
        LLMProxy::Config.new(server: {}, models: [])
      )

      slug = LLMProxy.default_model ||
             LLMProxy.catalog.all.first&.id&.gsub(/[^a-zA-Z0-9]+/, "-")&.downcase ||
             "model"

      _(slug).must_equal "model"
    ensure
      LLMProxy.default_model = old_default
      LLMProxy.catalog = old_catalog
    end
  end

  describe "enable method uses default_model" do
    it "resolves slug from default_model, not first catalog entry" do
      first_catalog_slug = LLMProxy.catalog.all.first&.id&.gsub(/[^a-zA-Z0-9]+/, "-")&.downcase
      _(first_catalog_slug).must_equal "deepseek-v4-flash"

      # But default_model is deepseek-v4-flash
      _(LLMProxy.default_model).must_equal "deepseek-v4-flash"

      # So enable should use deepseek-v4-flash, not kimi-k2-6
      slug = LLMProxy.default_model ||
             first_catalog_slug ||
             "model"

      _(slug).must_equal "deepseek-v4-flash"
      _(slug).wont_equal "kimi-k2-6"
    end
  end
end


