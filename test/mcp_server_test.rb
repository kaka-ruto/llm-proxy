# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"
require "timeout"
require "tmpdir"

class MCPServerTest < Minitest::Test
  TIMEOUT = 10

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
          return JSON.parse(line, symbolize_names: true)
        end
      end
    end
  rescue Timeout::Error
    raise "Timeout after #{timeout}s\nBuffer: #{buffer.inspect}"
  end

  def initialize_session
    send_line('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    resp = read_response
    raise "Init failed: #{resp[:error]}" if resp[:error]
    send_line('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    resp
  end

  def call_tool(name, arguments = {}, id: 2)
    msg = { jsonrpc: "2.0", id: id, method: "tools/call",
            params: { name: name, arguments: arguments } }
    send_line(msg.to_json)
    read_response
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

  # ===================== Protocol Lifecycle =====================

  def test_initialize_handshake
    start_server
    resp = initialize_session
    assert_equal "llm-proxy", resp[:result][:serverInfo][:name]
    assert_equal "2024-11-05", resp[:result][:protocolVersion]
    assert resp[:result][:capabilities][:tools]
  end

  def test_tools_list_returns_only_two_tools
    start_server; initialize_session
    send_line('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
    resp = read_response
    names = resp[:result][:tools].map { |t| t[:name] }
    assert_equal 2, names.size
    assert_includes names, "apply_patch"
    assert_includes names, "web_search"
  end

  def test_tools_list_definitions_have_schemas
    start_server; initialize_session
    send_line('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
    resp = read_response
    tools = resp[:result][:tools]

    ap = tools.find { |t| t[:name] == "apply_patch" }
    assert ap[:inputSchema][:properties].key?(:patchText) || ap[:inputSchema][:properties].key?("patchText")
    assert_includes ap[:inputSchema][:required], "patchText"

    ws = tools.find { |t| t[:name] == "web_search" }
    assert ws[:inputSchema][:properties].key?(:query) || ws[:inputSchema][:properties].key?("query")
    assert_includes ws[:inputSchema][:required], "query"
  end

  def test_tools_list_before_initialize_returns_error
    start_server
    send_line('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
    assert read_response[:error]
  end

  def test_unknown_method_returns_error
    start_server; initialize_session
    send_line('{"jsonrpc":"2.0","id":5,"method":"bogus/method"}')
    assert_equal(-32601, read_response[:error][:code])
  end

  def test_ping_returns_empty_result
    start_server; initialize_session
    send_line('{"jsonrpc":"2.0","id":6,"method":"ping"}')
    assert_equal({}, read_response[:result])
  end

  # ===================== apply_patch: Add =====================

  def test_apply_patch_adds_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "new.txt")
      patch = "*** Begin Patch\n*** Add File: #{path}\n+hello world\n*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      refute resp.dig(:result, :isError)
      assert File.exist?(path)
      assert_equal "hello world\n", File.read(path)
    end
  end

  def test_apply_patch_adds_file_with_multiple_lines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "multi.txt")
      content = "line one\nline two\nline three"
      patch = "*** Begin Patch\n*** Add File: #{path}\n+#{content}\n*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      refute resp.dig(:result, :isError)
      assert_equal content + "\n", File.read(path)
    end
  end

  def test_apply_patch_add_existing_file_returns_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "exists.txt")
      File.write(path, "existing")
      patch = "*** Begin Patch\n*** Add File: #{path}\n+new\n*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      assert resp.dig(:result, :isError)
    end
  end

  # ===================== apply_patch: Update =====================

  def test_apply_patch_updates_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "update.txt")
      File.write(path, "old line\n")
      patch = "*** Begin Patch\n*** Update File: #{path}\n@@\n-old line\n+new line\n*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      refute resp.dig(:result, :isError)
      assert_equal "new line\n", File.read(path)
    end
  end

  def test_apply_patch_updates_with_multiple_hunks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hunks.txt")
      File.write(path, "a\nb\nc\n")
      patch = "*** Begin Patch\n*** Update File: #{path}\n@@\n-a\n+A\n@@\n-c\n+C\n*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      refute resp.dig(:result, :isError)
      assert_equal "A\nb\nC\n", File.read(path)
    end
  end

  def test_apply_patch_update_nonexistent_file_returns_error
    patch = "*** Begin Patch\n*** Update File: /nope/missing.txt\n@@\n-old\n+new\n*** End Patch"
    start_server; initialize_session
    resp = call_tool("apply_patch", { "patchText" => patch })
    assert resp.dig(:result, :isError)
  end

  def test_apply_patch_update_mismatched_hunk_returns_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mismatch.txt")
      File.write(path, "actual\n")
      patch = "*** Begin Patch\n*** Update File: #{path}\n@@\n-wrong\n+right\n*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      assert resp.dig(:result, :isError)
    end
  end

  # ===================== apply_patch: Delete =====================

  def test_apply_patch_deletes_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "del.txt")
      File.write(path, "bye")
      patch = "*** Begin Patch\n*** Delete File: #{path}\n*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      refute resp.dig(:result, :isError)
      refute File.exist?(path)
    end
  end

  def test_apply_patch_delete_nonexistent_file_returns_error
    patch = "*** Begin Patch\n*** Delete File: /nope/ghost.txt\n*** End Patch"
    start_server; initialize_session
    resp = call_tool("apply_patch", { "patchText" => patch })
    assert resp.dig(:result, :isError)
  end

  # ===================== apply_patch: Edge Cases =====================

  def test_apply_patch_with_unicode
    Dir.mktmpdir do |dir|
      path = File.join(dir, "uni.txt")
      patch = "*** Begin Patch\n*** Add File: #{path}\n+héllò 😊\n*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      refute resp.dig(:result, :isError)
      assert_equal "héllò 😊\n", File.read(path, encoding: "UTF-8")
    end
  end

  def test_apply_patch_with_many_hunks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "large.txt")
      lines = (1..100).map { |i| "line #{i}" }
      File.write(path, lines.join("\n") + "\n")
      hunks = (1..50).map { |i| "@@\n-line #{i * 2}\n+line #{i * 2} mod\n" }.join
      patch = "*** Begin Patch\n*** Update File: #{path}\n#{hunks}*** End Patch"
      start_server; initialize_session
      resp = call_tool("apply_patch", { "patchText" => patch })
      refute resp.dig(:result, :isError)
      assert_includes File.read(path), "line 2 mod"
    end
  end

  def test_apply_patch_no_valid_sections_returns_error
    start_server; initialize_session
    resp = call_tool("apply_patch", { "patchText" => "random text" })
    assert resp.dig(:result, :isError)
  end

  # ===================== web_search =====================

  def test_web_search_returns_valid_structure
    start_server; initialize_session
    resp = call_tool("web_search", { "query" => "ruby" })
    assert resp[:result], "Expected result, got: #{resp[:error]}"
    assert_kind_of Array, resp[:result][:content]
    text = resp[:result][:content].first[:text]
    assert text, "Should have text content"
    refute text.empty?, "Text should not be empty"
  end

  # ===================== Error Handling =====================

  def test_unknown_tool_returns_error
    start_server; initialize_session
    resp = call_tool("nonexistent", {})
    assert resp.dig(:result, :isError)
    assert_match(/Tool not found/, resp[:result][:content].first[:text])
  end

  def test_malformed_json_returns_parse_error
    start_server
    send_line("not valid json\n")
    assert_equal(-32700, read_response[:error][:code])
  end

  # ===================== Request Deduplication =====================

  def test_same_request_id_returns_cached_result
    start_server; initialize_session
    msg = '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"web_search","arguments":{"query":"test"}}}'
    send_line(msg)
    r1 = read_response
    send_line(msg)
    r2 = read_response
    assert_equal r1, r2
  end

  # ===================== Graceful Shutdown =====================

  def test_graceful_shutdown_on_stdin_close
    start_server; initialize_session
    @stdin.close
    assert @wait_thr.value.success?
  end

  def test_sigterm_triggers_shutdown
    start_server; initialize_session
    pid = @wait_thr.pid
    Process.kill("TERM", pid)
    begin
      Timeout.timeout(3) { @wait_thr.value }
    rescue Timeout::Error
      Process.kill("KILL", pid) rescue nil
      flunk "Server did not exit within 3s of SIGTERM"
    end
    refute @wait_thr.alive?
  end

  # ===================== Debug Mode =====================

  def test_debug_mode_emits_logs
    start_server(env: { "DEBUG" => "1" })
    assert_match(/llm-proxy/, wait_for_stderr(/Server starting/))
    initialize_session
    call_tool("web_search", { "query" => "x" })
    assert_match(/tools\/call/, wait_for_stderr(/tools\/call/))
  end

  def test_no_debug_no_stderr
    start_server; initialize_session
    call_tool("web_search", { "query" => "test" })
    sleep 0.2
    assert read_stderr.empty?, "Expected no stderr without DEBUG"
  end
end
