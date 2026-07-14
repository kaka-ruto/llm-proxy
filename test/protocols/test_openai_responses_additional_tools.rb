require_relative "../test_helper"

describe LLMProxy::Protocols::OpenAIResponses do
  include TestSupport

  before do
    @protocol = LLMProxy::Protocols::OpenAIResponses.new
  end

  describe "additional_tools in normalize" do
    it "ignores additional_tools as messages" do
      body = {
        "input" => [
          { "type" => "additional_tools", "role" => "developer", "tools" => [
            { "type" => "custom", "name" => "exec_command", "description" => "Run commands" }
          ]},
          { "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => "Hello" }]}
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:messages].size).must_equal 1
      _(normalized[:messages].first[:content]).must_equal "Hello"
    end

    it "extracts tools from additional_tools items" do
      body = {
        "input" => [
          { "type" => "additional_tools", "role" => "developer", "tools" => [
            { "type" => "custom", "name" => "web_search", "description" => "Search the web" }
          ]}
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:tools].size).must_equal 1
      _(normalized[:tools].first[:name]).must_equal "web_search"
    end

    it "merges additional_tools with top-level tools" do
      body = {
        "input" => [
          { "type" => "additional_tools", "role" => "developer", "tools" => [
            { "type" => "custom", "name" => "exec_command", "description" => "Run commands" }
          ]}
        ],
        "tools" => [
          { "type" => "function", "function" => { "name" => "apply_patch", "description" => "Patch files" } }
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:tools].size).must_equal 2
      names = normalized[:tools].map { |t| t[:name] }
      _(names).must_include "exec_command"
      _(names).must_include "apply_patch"
    end

    it "handles additional_tools with no top-level tools" do
      body = {
        "input" => [
          { "type" => "additional_tools", "role" => "developer", "tools" => [
            { "type" => "custom", "name" => "exec_command", "description" => "Run commands", "parameters" => { "type" => "object", "properties" => { "cmd" => { "type" => "string" } } } }
          ]}
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:tools].size).must_equal 1
      _(normalized[:tools].first[:name]).must_equal "exec_command"
    end

    it "handles multiple additional_tools items" do
      body = {
        "input" => [
          { "type" => "additional_tools", "role" => "developer", "tools" => [
            { "type" => "custom", "name" => "exec_command" }
          ]},
          { "type" => "additional_tools", "role" => "developer", "tools" => [
            { "type" => "custom", "name" => "web_search" }
          ]},
          { "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => "Hi" }]}
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:tools].size).must_equal 2
      _(normalized[:messages].size).must_equal 1
    end

    it "deduplicates tools with same name from both sources" do
      body = {
        "input" => [
          { "type" => "additional_tools", "role" => "developer", "tools" => [
            { "type" => "custom", "name" => "exec_command", "description" => "Run commands" }
          ]}
        ],
        "tools" => [
          { "type" => "function", "function" => { "name" => "exec_command", "description" => "Run commands" } }
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:tools].size).must_equal 1
      _(normalized[:tools].first[:name]).must_equal "exec_command"
    end

    it "preserves all parameters for tools from additional_tools" do
      body = {
        "input" => [
          { "type" => "additional_tools", "role" => "developer", "tools" => [
            {
              "type" => "custom",
              "name" => "read_file",
              "description" => "Read file contents",
              "parameters" => {
                "type" => "object",
                "properties" => { "path" => { "type" => "string" } },
                "required" => ["path"]
              }
            }
          ]}
        ]
      }
      normalized = @protocol.normalize(body)
      _(normalized[:tools].size).must_equal 1
      tool = normalized[:tools].first
      _(tool[:name]).must_equal "read_file"
      _(tool[:description]).must_equal "Read file contents"
      _(tool[:parameters]["required"]).must_equal ["path"]
    end
  end
end
