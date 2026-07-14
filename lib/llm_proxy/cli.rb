module LLMProxy
  module CLI
    COMMANDS = %w[server enable disable].freeze
    CLIENTS = %w[codex zcode].freeze
    DEFAULT_CLIENT = "codex".freeze

    def self.run!(args = ARGV)
      load_env

      require "ask/llm/catalog"
      Ask::LLM::Catalog.load!

      config_path = ENV.fetch("LLM_PROXY_CONFIG", File.expand_path("../../config.yml", __dir__))
      config = LLMProxy::Config.load(config_path)
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
        client, model = parse_client_args(rest)
        case client
        when "codex"
          Codex.enable(resolve_model(model, config), config)
        when "zcode"
          ZCode.enable(resolve_model(model, config), config)
        else
          warn "Unknown client: #{client}. Supported: #{CLIENTS.join(", ")}"
          exit 1
        end
      when "mcp"
        LLMProxy::MCPServer.start

      when "disable"
        client, = parse_client_args(rest)
        case client
        when "codex"
          Codex.disable
        when "zcode"
          ZCode.disable
        else
          warn "Unknown client: #{client}. Supported: #{CLIENTS.join(", ")}"
          exit 1
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

      File.chmod(0600, dotenv) unless File.stat(dotenv).mode & 077 == 0

      File.readlines(dotenv).each do |line|
        next if line.strip.empty? || line.start_with?("#")
        key, value = line.strip.split("=", 2)
        value = value&.strip&.tr("'\"", "")
        ENV[key] = value if key && value && !value.empty?
      end
    end

    # Parse `enable`/`disable` arguments: an optional client name
    # (codex|zcode, defaults to codex) and, for enable only, --model MODEL_ID.
    # Accepts `--model X`, `--model=X`, or a bare positional model id.
    def self.parse_client_args(args)
      client = DEFAULT_CLIENT
      model = nil
      expect_model_next = false

      args.each_with_index do |arg, _i|
        if expect_model_next
          model = arg
          expect_model_next = false
          next
        end

        case arg
        when /\A--model=(.+)\z/
          model = Regexp.last_match(1)
        when "--model"
          expect_model_next = true
        when /\A--/
          warn "Unknown option: #{arg}"
          exit 1
        when *CLIENTS
          client = arg
        else
          model = arg
        end
      end

      if expect_model_next
        warn "--model requires a value"
        exit 1
      end

      [client, model]
    end

    # Resolve the model id from --model, else default_model, else first catalog
    # model id. Matches the fallback chain the Codex tests previously asserted.
    def self.resolve_model(explicit, _config)
      explicit ||
        LLMProxy.default_model ||
        Ask::ModelCatalog.instance.all.first&.id ||
        "model"
    end

    def self.start_server(config)
      host = config.server[:host] || "127.0.0.1"
      port = config.server[:port] || 8765
      env = (config.server[:environment] || "production").to_sym

      default_model = LLMProxy.default_model || "not set"
      puts "LLM Proxy v0.1.0 — http://#{host}:#{port}"
      puts "  Config: #{ENV.fetch("LLM_PROXY_CONFIG", "config.yml")}"
      puts "  Models: #{Ask::ModelCatalog.instance.all.size} (default: #{default_model})"
      puts ""
      puts "  POST /v1/chat/completions   — OpenAI Chat (Cursor, Aider)"
      puts "  POST /v1/responses           — OpenAI Responses (Codex Desktop)"
      puts "  POST /v1/messages            — Anthropic Messages (Claude Code, ZCode)"
      puts "  GET  /v1/models              — List models"
      puts "  GET  /health                 — Health check"
      puts ""
      puts "  Test: curl http://#{host}:#{port}/v1/chat/completions \\"
      puts "    -H 'Content-Type: application/json' \\"
      puts "    -d '{\"model\":\"#{default_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"

      LLMProxy::Server.set :port, port
      LLMProxy::Server.set :bind, host
      LLMProxy::Server.set :environment, env.to_s
      LLMProxy::Server.run!
    end

    def self.print_help
      puts "Usage: llm-proxy [command]"
      puts ""
      puts "Commands:"
      puts "  enable [codex|zcode] [--model ID]  Route a client through llm-proxy"
      puts "  disable [codex|zcode]              Restore a client to its native config"
      puts "  server                             Start the proxy server (default)"
      puts "  login                              Log in to ChatGPT OAuth"
      puts "  -h, --help                         Show this help"
      puts "  -v, --version                      Show version"
      puts ""
      puts "Clients (default: codex):"
      puts "  codex   Codex Desktop  — writes ~/.codex/config.toml (OpenAI Responses)"
      puts "  zcode   ZCode          — writes ~/.zcode/v2/config.json (Anthropic Messages)"
      puts ""
      puts "Endpoints:"
      puts "  POST /api/goals          Goal management (Codex /goal support)"
      puts ""
      puts "Env:"
      puts "  LLM_PROXY_CONFIG    Path to config.yml (default: config.yml)"
      puts "  OPENCODE_API_KEY    OpenCode API key"
      puts "  OPENROUTER_API_KEY  OpenRouter API key"
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
