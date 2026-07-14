require_relative "test_helper"

describe LLMProxy::Config do
  it "loads config from YAML" do
    config = LLMProxy::Config.load(CONFIG_PATH)
    _(config).must_be_kind_of LLMProxy::Config
    _(config.server[:host]).must_equal "127.0.0.1"
    _(config.server[:port]).must_equal 8765
    _(config.server[:default_model]).must_equal "deepseek-v4-flash"
  end
end
