# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"
require "timeout"

class MCPServerTest < Minitest::Test
  TIMEOUT = 5

  def script_path
    File.expand_path("support/llm_proxy_mcp.rb", __dir__)
  end

  def teardown
    @stdin&.close rescue nil
    @stdout&.close rescue nil
    @stderr&.close rescue nil
    @wait_thr&.value rescue nil
  end

  def start_server(env: {})
    merged = { "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__) }.merge(env)
    @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(merged, "ruby", script_path)
    @stdin.sync = true
  end

  def send_line(line)
    @stdin.puts(line)
    @stdin.flush
  end

  def read_response(timeout: TIMEOUT)
    buffer = +""
    Timeout.timeout(timeout) do
      loop do
        char = @stdout.getc
        return nil if char.nil?
        buffer << char
        if buffer.end_with?("\n")
          line = buffer.strip
          buffer = +""
          next if line.empty?
          parsed = JSON.parse(line, symbolize_names: true)
          return parsed if parsed.key?(:id)
        end
      end
    end
  rescue Timeout::Error
    raise "Timeout after #{timeout}s\nBuffer: #{buffer.inspect}"
  end

  def initialize_session
    send_line('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"0.1.0","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    resp = read_response
    raise "Init failed: #{resp[:error]}" if resp[:error]
    send_line('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    resp
  end

  def read_stderr
    output = +""
    begin
      while (char = @stderr.read_nonblock(4096))
        output << char
      end
    rescue IO::WaitReadable, EOFError, Errno::EAGAIN
    rescue IOError
    end
    output
  end

  def wait_for_stderr(pattern, timeout: 3)
    Timeout.timeout(timeout) do
      loop do
        output = read_stderr
        return output if output.match?(pattern)
        sleep 0.05
      end
    end
  rescue Timeout::Error
    raise "Timeout waiting for #{pattern.inspect} on stderr"
  end

  # --- Tests ---

  def test_initialize_handshake
    start_server
    resp = initialize_session
    assert_equal "llm-proxy", resp[:result][:serverInfo][:name]
  end

  def test_tools_list_exposes_only_apply_patch_and_web_search
    start_server
    initialize_session
    send_line('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
    resp = read_response
    tools = resp[:result][:tools]
    names = tools.map { |t| t[:name] }
    assert_includes names, "apply_patch"
    assert_includes names, "web_search"
    assert_equal 2, names.size, "Should only expose apply_patch and web_search"
  end

  def test_tool_call_unknown_tool_returns_error
    start_server
    initialize_session
    send_line('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}')
    resp = read_response
    assert resp[:result], "Expected result, got: #{resp[:error]}"
    assert resp.dig(:result, :isError), "Expected error for unknown tool"
  end

  def test_graceful_shutdown
    start_server
    initialize_session
    @stdin.close
    exit_status = @wait_thr.value
    assert exit_status.success?, "Expected clean exit"
  end

  def test_debug_mode
    start_server(env: { "DEBUG" => "1" })
    stderr_out = wait_for_stderr(/Server starting/)
    assert_match(/llm-proxy/, stderr_out)
  end

  def test_no_debug_mode_no_stderr
    start_server
    initialize_session
    sleep 0.2
    stderr_out = read_stderr
    assert stderr_out.empty?, "Expected no stderr without DEBUG, got: #{stderr_out.inspect}"
  end
end
