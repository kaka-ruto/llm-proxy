module LLMProxy
  module CLI
    COMMANDS = %w[server codex].freeze

    def self.run!(args = ARGV)
      load_env

      config_path = ENV.fetch("LLM_PROXY_CONFIG", File.expand_path("../../config.yml", __dir__))
      config = LLMProxy::Config.load(config_path)
      LLMProxy.catalog = LLMProxy::ModelCatalog.new(config)
      LLMProxy.default_model = config.server[:default_model]
      configure_ruby_llm

      command = args.first
      rest = args.drop(1)

      case command
      when nil, "server"
        start_server(config)
      when "codex"
        handle_codex(rest, config)
      when "catalog"
        Codex.generate_catalog(LLMProxy.catalog.all, port: config.server[:port] || 8765)
      when "patch"
        Codex.patch_asar
      when "restore"
        Codex.restore_asar
      when "login"
        puts "Opening browser for ChatGPT login..."
        url = LLMProxy::OAuth.login_url
        system("open", url)
        puts "Waiting for OAuth callback on http://localhost:1455/auth/callback..."
        start_callback_server
      when "logout"
        LLMProxy::OAuth.logout
        puts "Signed out of ChatGPT."
      when "status"
        if LLMProxy::OAuth.logged_in?
          puts "Signed in to ChatGPT (account: #{LLMProxy::OAuth.get_account_id})"
        else
          puts "Not signed in to ChatGPT. Run: llm-proxy login"
        end
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

      File.readlines(dotenv).each do |line|
        next if line.strip.empty? || line.start_with?("#")
        key, value = line.strip.split("=", 2)
        value = value&.strip&.tr("'\"", "")
        ENV[key] = value if key && value && !value.empty?
      end
    end

    def self.configure_ruby_llm
      RubyLLM.configure do |c|
        c.opencode_api_key = ENV["OPENCODE_API_KEY"] if ENV["OPENCODE_API_KEY"]
        c.opencode_go_api_key = ENV["OPENCODE_API_KEY"] if ENV["OPENCODE_API_KEY"]
        c.openrouter_api_key = ENV["OPENROUTER_API_KEY"] if ENV["OPENROUTER_API_KEY"]
        c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] if ENV["ANTHROPIC_API_KEY"]
        c.openai_api_key = ENV["OPENAI_API_KEY"] if ENV["OPENAI_API_KEY"]
        c.gemini_api_key = ENV["GEMINI_API_KEY"] if ENV["GEMINI_API_KEY"]
        c.deepseek_api_key = ENV["DEEPSEEK_API_KEY"] if ENV["DEEPSEEK_API_KEY"]
        c.xai_api_key = ENV["XAI_API_KEY"] if ENV["XAI_API_KEY"]
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

    def self.handle_codex(args, config)
      sub = args.first
      rest = args.drop(1)

      case sub
      when nil, "launch"
        slug = rest.first
        Codex.launch_app(port: config.server[:port] || 8765, model_slug: slug)
      when "catalog"
        Codex.generate_catalog(LLMProxy.catalog.all, port: config.server[:port] || 8765)
      when "patch"
        Codex.patch_asar
      when "restore"
        Codex.restore_asar
      when "-h", "--help"
        puts "Usage: llm-proxy codex [launch|catalog|patch|restore] [model-slug]"
      else
        puts "Unknown codex subcommand: #{sub}"
      end
    end

    def self.print_help
      puts "Usage: llm-proxy [command]"
      puts ""
      puts "Commands:"
      puts "  server              Start the proxy server (default)"
      puts "  codex [launch]      Launch Codex Desktop with proxy models"
      puts "  codex catalog       Generate Codex model catalog"
      puts "  codex patch         Patch Codex ASAR for custom model picker"
      puts "  codex restore       Restore original Codex ASAR"
      puts "  catalog             Generate Codex model catalog only"
      puts "  patch               Patch Codex ASAR only"
      puts "  restore             Restore Codex ASAR only"
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
