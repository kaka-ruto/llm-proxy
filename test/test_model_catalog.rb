require_relative "test_helper"

describe LLMProxy::ModelCatalog do
  include TestSupport

  before do
    setup_catalog
  end

  it "loads models from config" do
    catalog = LLMProxy.catalog
    _(catalog.all.size).must_be :>, 0
  end

  it "looks up models by id" do
    model = LLMProxy.catalog.lookup("deepseek-v4-flash")
    _(model).wont_be_nil
    _(model.id).must_equal "deepseek-v4-flash"
    _(model.provider).must_equal "opencode"
  end

  it "looks up by slug (dash form)" do
    model = LLMProxy.catalog.lookup("kimi-k2-6")
    _(model).wont_be_nil
    _(model.id).must_equal "kimi-k2.6"
  end

  it "returns nil for unknown models" do
    _(LLMProxy.catalog.lookup("nonexistent")).must_be_nil
  end

  it "generates OpenAI-compatible model list" do
    list = LLMProxy.catalog.to_openai_list
    _(list).must_be_kind_of Array
    _(list.first).must_include :id
    _(list.first).must_include :owned_by
  end

  it "checks model capabilities" do
    model = LLMProxy.catalog.lookup("deepseek-v4-flash")
    _(model.supports?(:reasoning)).must_equal true
    _(model.supports?(:tools)).must_equal true
  end
end
