# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"
require "timeout"

class MCPServerWebSearchRealTest < Minitest::Test
  TIMEOUT = 10

  def script_path
    File.expand_path("support/llm_proxy_mcp.rb", __dir__)
  end

  def teardown
    @stdin&.close rescue nil; @stdout&.close rescue nil
    @stderr&.close rescue nil; @wait_thr&.value rescue nil
  end

  def start_server
    merged = { "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__) }
    @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(merged, "ruby", script_path)
    @stdin.sync = true
  end

  def send_line(line)
    @stdin.puts(line); @stdin.flush
  end

  def read_response(timeout: TIMEOUT)
    buffer = +""
    Timeout.timeout(timeout) do
      loop do
        char = @stdout.getc
        return nil if char.nil?
        buffer << char
        if buffer.end_with?("\n")
          line = buffer.strip; buffer = +""
          next if line.empty?
          return JSON.parse(line, symbolize_names: true)
        end
      end
    end
  rescue Timeout::Error
    raise "Timeout\nBuffer: #{buffer.inspect}"
  end

  def test_web_search_returns_real_results
    start_server
    send_line('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    read_response
    send_line('{"jsonrpc":"2.0","method":"notifications/initialized"}')

    send_line('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"web_search","arguments":{"query":"ruby programming language"}}}')
    resp = read_response

    refute resp[:error], "Got error response: #{resp[:error]}"
    refute resp.dig(:result, :isError), "web_search returned isError=true"
    assert_kind_of Array, resp[:result][:content]

    text = resp[:result][:content].first[:text]
    assert text.length > 100, "Response too short: #{text.length} chars"
    assert_match(/^\d+\./, text, "Should have numbered results")
    assert_includes text, "https://", "Should contain URLs"
    assert_includes text, "Ruby", "Should contain relevant content"
  end
end
