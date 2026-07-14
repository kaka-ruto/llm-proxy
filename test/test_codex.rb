require_relative "test_helper"

describe LLMProxy::Codex do
  before do
    Ask::ModelCatalog.reset_instance!
    Ask::LLM::Catalog.load!
    config = LLMProxy::Config.load(CONFIG_PATH)
    LLMProxy.default_model = config.server[:default_model]
    LLMProxy.default_provider = config.server[:default_provider]
  end

  describe "default_model from config" do
    it "is set to deepseek-v4-flash" do
      _(LLMProxy.default_model).must_equal "deepseek-v4-flash"
    end
  end

  describe "slug resolution (the enable logic)" do
    it "uses LLMProxy.default_model when set" do
      slug = LLMProxy.default_model ||
             Ask::ModelCatalog.instance.all.first&.id ||
             "model"

      _(slug).must_equal "deepseek-v4-flash"
    end

    it "falls back to first catalog model when default_model is nil" do
      old_default = LLMProxy.default_model
      LLMProxy.default_model = nil

      slug = LLMProxy.default_model ||
             Ask::ModelCatalog.instance.all.first&.id ||
             "model"

      _(slug).wont_be_nil
      _(slug).wont_equal "model"
    ensure
      LLMProxy.default_model = old_default
    end

    it "falls back to 'model' when both default and catalog are empty" do
      old_default = LLMProxy.default_model

      LLMProxy.default_model = nil
      Ask::ModelCatalog.reset_instance!

      slug = LLMProxy.default_model ||
             Ask::ModelCatalog.instance.all.first&.id ||
             "model"

      _(slug).must_equal "model"
    ensure
      LLMProxy.default_model = old_default
      Ask::LLM::Catalog.load!
    end
  end

  describe "enable method uses default_model" do
    it "resolves model from default_model, not first catalog entry" do
      first_model = Ask::ModelCatalog.instance.all.first&.id

      # But default_model is deepseek-v4-flash
      _(LLMProxy.default_model).must_equal "deepseek-v4-flash"

      slug = LLMProxy.default_model ||
             first_model ||
             "model"

      _(slug).must_equal "deepseek-v4-flash"
    end
  end
end
