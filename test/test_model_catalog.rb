require_relative "test_helper"

describe "Ask::LLM::Catalog (via proxy)" do
  include TestSupport

  before do
    Ask::ModelCatalog.reset_instance!
    setup_catalog
  end

  it "loads models from bundled JSON files" do
    _(Ask::ModelCatalog.instance.all.size).must_be :>, 50
  end

  it "looks up models by id" do
    model = Ask::ModelCatalog.find("deepseek-v4-flash")
    _(model).wont_be_nil
    _(model.id).must_equal "deepseek-v4-flash"
    _(model.provider).must_equal "opencode"
  end

  it "returns nil for unknown models" do
    _(Ask::ModelCatalog.find("nonexistent")).must_be_nil
  rescue Ask::ModelNotFound
    :expected
  end

  it "resolves model aliases" do
    model = Ask::ModelCatalog.find("deepseek-v4")
    _(model).wont_be_nil
    _(model.id).must_equal "deepseek-v4"
  end

  it "generates OpenAI-compatible model list" do
    list = Ask::ModelCatalog.instance.all.map { |m|
      { id: m.id, object: "model", created: Time.now.to_i, owned_by: m.provider }
    }
    _(list).must_be_kind_of Array
    _(list.first).must_include :id
    _(list.first).must_include :owned_by
  end

  it "checks model capabilities" do
    model = Ask::ModelCatalog.find("deepseek-v4-flash")
    _(model.supports?(:reasoning)).must_equal true
    _(model.supports?(:function_calling)).must_equal true
  end
end
