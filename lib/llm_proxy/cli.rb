module LLMProxy
  module CLI
    COMMANDS = %w[server enable disable].freeze

    def self.run!(args = ARGV)
      load_env

      config_path = ENV.fetch("LLM_PROXY_CONFIG", File.expand_path("../../config.yml", __dir__))
      config = LLMProxy::Config.load(config_path)
      LLMProxy.catalog = LLMProxy::ModelCatalog.new(config)
      LLMProxy.default_model = config.server[:default_model]

      command = args.first
      rest = args.drop(1)

      case command
      when nil, "server"
        start_server(config)
      when "login"
        puts "Opening browser for ChatGPT login..."
        url = LLMProxy::OAuth.login_url
        system("open", url)
        puts "Waiting for OAuth callback on http://localhost:1455/auth/callback..."
        start_callback_server
      when "enable"
        Codex.enable(LLMProxy.default_model, config)
      when "disable"
        Codex.disable
      when "-h", "--help"
        print_help
      when "-v", "--version"
        puts "llm-proxy v0.1.0"
      else
        puts "Unknown command: #{command}"
        print_help
        exit 1
      end
    end

    private

    def self.load_env
      dotenv = File.expand_path("../../.env", __dir__)
      return unless File.exist?(dotenv)

      File.chmod(0600, dotenv) unless File.stat(dotenv).mode & 077 == 0

      File.readlines(dotenv).each do |line|
        next if line.strip.empty? || line.start_with?("#")
        key, value = line.strip.split("=", 2)
        value = value&.strip&.tr("'\"", "")
        ENV[key] = value if key && value && !value.empty?
      end
    end

    def self.start_server(config)
      host = config.server[:host] || "127.0.0.1"
      port = config.server[:port] || 8765
      env = (config.server[:environment] || "production").to_sym

      puts "LLM Proxy v0.1.0 — http://#{host}:#{port}"
      puts "  Config: #{ENV.fetch("LLM_PROXY_CONFIG", "config.yml")}"
      puts "  Models: #{LLMProxy.catalog.all.size}"
      puts ""
      puts "  POST /v1/chat/completions   — OpenAI Chat (Cursor, Aider)"
      puts "  POST /v1/responses           — OpenAI Responses (Codex Desktop)"
      puts "  POST /v1/messages            — Anthropic Messages (Claude Code)"
      puts "  GET  /v1/models              — List models"
      puts "  GET  /health                 — Health check"

      LLMProxy::Server.set :port, port
      LLMProxy::Server.set :bind, host
      LLMProxy::Server.set :environment, env.to_s
      LLMProxy::Server.run!
    end

    def self.print_help
      puts "Usage: llm-proxy [command]"
      puts ""
      puts "Commands:"
      puts "  enable              Route Codex through llm-proxy (config.toml)"
      puts "  disable             Restore Codex to native (config.toml)"
      puts "  server              Start the proxy server (default)"
      puts "  login               Log in to ChatGPT OAuth"
      puts "  -h, --help          Show this help"
      puts "  -v, --version       Show version"
      puts ""
      puts "Env:"
      puts "  LLM_PROXY_CONFIG    Path to config.yml (default: config.yml)"
      puts "  OPENCODE_API_KEY    Your OpenCode API key"
      puts "  OPENROUTER_API_KEY  Your OpenRouter API key"
    end

    def self.start_callback_server
      require "socket"

      server = TCPServer.new("127.0.0.1", 1455)
      puts "  Listening on http://127.0.0.1:1455/auth/callback"

      client = server.accept
      request = client.gets
      path = request&.split(" ")&.[](1) || ""

      result = nil

      if path.start_with?("/auth/callback")
        query = URI.decode_www_form(path.split("?").last || "").to_h rescue {}
        result = LLMProxy::OAuth.handle_callback(code: query["code"], state: query["state"])

        if result[:success]
          body = "<html><body><h1>✅ Signed in to ChatGPT</h1><p>Account: #{result[:account_id]}</p><p>You can close this window.</p></body></html>"
        else
          body = "<html><body><h1>❌ Login failed</h1><p>#{result[:error]}</p></body></html>"
        end

        client.puts "HTTP/1.1 200 OK"
        client.puts "Content-Type: text/html"
        client.puts "Content-Length: #{body.bytesize}"
        client.puts "Connection: close"
        client.puts
        client.puts body
      end

      client.close
      server.close

      if result && result[:success]
        puts "  ✅ Signed in to ChatGPT (account: #{result[:account_id]})"
      else
        puts "  ❌ Login failed: #{result&.dig(:error) || 'Unknown error'}"
      end
    rescue => e
      puts "  ❌ OAuth error: #{e.message}"
    end
  end
end
