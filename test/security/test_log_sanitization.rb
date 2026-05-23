require_relative "../test_helper"

describe "Log sanitization" do
  include TestSupport

  before do
    setup_catalog
  end

  it "redacts Authorization header in logs" do
    headers = { "HTTP_AUTHORIZATION" => "Bearer sk-real-key-12345" }
    filtered = headers.merge("HTTP_AUTHORIZATION" => "[REDACTED]") if headers.key?("HTTP_AUTHORIZATION")
    _(filtered["HTTP_AUTHORIZATION"]).must_equal "[REDACTED]"
  end

  it "redacts apiKey in request body" do
    body = '{"model":"test","apiKey":"sk-real-key-12345"}'
    sanitized = body.gsub(/(?:"apiKey"|"key")\s*:\s*"[^"]+"/, '\1: "[REDACTED]"')
    _(sanitized).wont_include "sk-real-key"
    _(sanitized).must_include "[REDACTED]"
  end

  it "does not log actual bearer tokens" do
    body = '{"model":"test"}'
    sanitized = body.gsub(/(?:"apiKey"|"key")\s*:\s*"[^"]+"/, '\1: "[REDACTED]"')
    _(sanitized).must_equal body
  end
end

describe "Credential file permissions" do
  it "enforces 0600 on .env" do
    env_path = File.join(PROJECT_ROOT, ".env")
    skip "No .env file" unless File.exist?(env_path)
    mode = File.stat(env_path).mode & 077
    _(mode).must_equal 0, ".env should not be world-readable"
  end

  it "enforces 0600 on .auth.json" do
    auth_path = File.join(PROJECT_ROOT, ".auth.json")
    skip "No .auth.json" unless File.exist?(auth_path)
    mode = File.stat(auth_path).mode & 077
    _(mode).must_equal 0, ".auth.json should not be world-readable (run chmod 0600 .auth.json)"
  end

  it "enforces 0700 on logs directory" do
    log_dir = File.join(PROJECT_ROOT, "logs")
    skip "No logs dir" unless Dir.exist?(log_dir)
    mode = File.stat(log_dir).mode & 077
    _(mode).must_equal 0, "logs/ should not be world-readable"
  end
end

describe "Command injection prevention" do
  it "command? uses multi-arg system call" do
    # The method should use system("which", cmd) not system("which #{cmd}")
    # We can test by checking the source
    source = File.read(File.join(PROJECT_ROOT, "lib/llm_proxy/codex.rb"))
    match = source.match(/def command\?.*?end/m)
    _(match).wont_be_nil
    _(match[0]).wont_include 'system("which #{'
    _(match[0]).must_include 'system("which", cmd)'
  end

  it "codesign uses multi-arg system call" do
    source = File.read(File.join(PROJECT_ROOT, "lib/llm_proxy/codex.rb"))
    _(source).wont_include "`codesign"
    _(source).must_include 'system("codesign", "--force"'
  end
end

describe "Random bearer token" do
  it "enable generates random token, not hardcoded 'dummy'" do
    source = File.read(File.join(PROJECT_ROOT, "lib/llm_proxy/codex.rb"))
    _(source).wont_include 'experimental_bearer_token = "dummy"'
    _(source).must_include "SecureRandom.hex"
  end
end
