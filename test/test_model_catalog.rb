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

  it "finds a model by id (single result)" do
    model = Ask::ModelCatalog.find("deepseek-v4-flash")
    _(model.id).must_equal "deepseek-v4-flash"
  end

  it "finds a model scoped to provider" do
    model = Ask::ModelCatalog.find("deepseek-v4-flash", provider: "opencode")
    _(model.provider).must_equal "opencode"
  end

  it "raises for unknown models" do
    _{ Ask::ModelCatalog.find("nonexistent") }.must_raise Ask::ModelNotFound
  end

  it "returns all matches via where" do
    models = Ask::ModelCatalog.where("deepseek-v4-flash")
    _(models.length).must_be :>=, 2
    _(models.map(&:provider)).must_include "opencode"
    _(models.map(&:provider)).must_include "deepseek"
  end

  it "returns empty array for unknown via where" do
    _(Ask::ModelCatalog.where("nonexistent")).must_equal []
  end

  it "resolves model aliases" do
    model = Ask::ModelCatalog.find("deepseek-v4")
    _(model.id).must_equal "deepseek-v4"
  end

  it "checks model capabilities" do
    model = Ask::ModelCatalog.find("deepseek-v4-flash", provider: "opencode")
    _(model.supports?(:reasoning)).must_equal true
    _(model.supports?(:function_calling)).must_equal true
  end
end
