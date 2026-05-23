require_relative "test_helper"

describe LLMProxy::Config do
  it "loads config from YAML" do
    config = LLMProxy::Config.load(CONFIG_PATH)
    _(config).must_be_kind_of LLMProxy::Config
    _(config.server[:host]).must_equal "127.0.0.1"
    _(config.server[:port]).must_equal 8765
    _(config.models).wont_be :empty?
  end

  it "parses model entries" do
    config = LLMProxy::Config.load(CONFIG_PATH)
    model = config.models.first
    _(model).must_be_kind_of LLMProxy::ModelConfig
    _(model.id).wont_be_nil
    _(model.provider).wont_be_nil
    _(model.capabilities).must_be_kind_of Array
  end

  it "sets up ModelConfig correctly" do
    config = LLMProxy::Config.load(CONFIG_PATH)
    model = config.models.find { |m| m.id == "deepseek-v4-flash" }
    _(model.context_window).wont_be_nil
    _(model.max_tokens).wont_be_nil
    _(model.supports?(:tools)).must_equal true
    _(model.supports?(:vision)).must_equal false
  end
end
