# frozen_string_literal: true

require "fileutils"
require_relative "../lib/llm_proxy"

class CodexProxyTest < Minitest::Test
  PROXY_DIR = File.expand_path("..", __dir__)

  def test_project_root_has_bin_llm_proxy
    assert File.exist?(File.join(PROXY_DIR, "bin", "llm-proxy")),
      "bin/llm-proxy not found at #{PROXY_DIR}"
  end

  def test_mitm_addon_exists
    assert File.exist?(File.join(PROXY_DIR, "mitm_addon.py")),
      "mitm_addon.py not found at #{PROXY_DIR}"
  end

  def test_logs_directory_writable
    log_dir = File.join(PROXY_DIR, "logs")
    FileUtils.mkdir_p(log_dir)
    assert File.writable?(log_dir), "logs/ not writable"
  end

  def test_codex_app_exists
    assert File.exist?("/Applications/Codex.app/Contents/MacOS/Codex"),
      "Codex app not found at /Applications/Codex.app"
  end

  def test_script_path_resolution
    # Simulates the path logic in bin/codex-with-proxy
    script_dir = File.join(PROXY_DIR, "bin")
    resolved = File.expand_path("..", script_dir)
    assert_equal PROXY_DIR, resolved
  end

  def test_proxy_health
    # Check if llm-proxy is running and healthy
    skip "llm-proxy not running" unless system("lsof -ti :8765 > /dev/null 2>&1")

    require "net/http"
    uri = URI("http://127.0.0.1:8765/health")
    resp = Net::HTTP.get_response(uri)
    assert_equal "200", resp.code
    body = JSON.parse(resp.body)
    assert body["models"].is_a?(Integer)
    assert body["models"] > 0
  end

  def test_mitmproxy_installed
    assert system("which mitmdump > /dev/null 2>&1"),
      "mitmdump not found on PATH. Install: brew install mitmproxy"
  end

  def test_mitmproxy_ca_installed
    assert File.exist?(File.expand_path("~/.mitmproxy/mitmproxy-ca-cert.pem")),
      "mitmproxy CA cert not found. Run mitmdump once to generate it."
  end
end
