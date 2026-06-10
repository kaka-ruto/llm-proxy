module LLMProxy
  module CLI
    COMMANDS = %w[server codex].freeze

    def self.run!(args = ARGV)
      load_env

      config_path = ENV.fetch("LLM_PROXY_CONFIG", File.expand_path("../../config.yml", __dir__))
      config = LLMProxy::Config.load(config_path)
      LLMProxy.catalog = LLMProxy::ModelCatalog.new(config)
      LLMProxy.default_model = config.server[:default_model]
      configure_ask

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
      when "re-patch"
        puts "Restoring latest backup and re-patching..."
        Codex.restore
        Codex.patch_asar
      when "restore"
        if rest.empty? || rest.first == "latest"
          Codex.restore
        elsif rest.first == "oldest"
          Codex.restore_asar
        else
          Codex.restore(build: rest.first)
  # Providers register themselves when loaded via Ask::Provider.register
      when "login"
        puts "Opening browser for ChatGPT login..."
        url = LLMProxy::OAuth.login_url
        system("open", url)
        puts "Waiting for OAuth callback on http://localhost:1455/auth/callback..."
        start_callback_server
      when "enable"
        Codex.enable(port: config.server[:port] || 8765)
        puts "Quit and reopen Codex to see proxy models."
      when "disable"
        Codex.disable
        puts "Quit and reopen Codex to restore native models."
      when "toggle"
        if Codex.enabled?
          Codex.disable
        else
          Codex.enable(port: config.server[:port] || 8765)
  # Providers register themselves when loaded via Ask::Provider.register
        puts "Quit and reopen Codex to see the change."
      when "backup"
        Codex.backup
      when "backups"
        list = Codex.list_backups
        if list.empty?
          puts "No backups yet. Run: llm-proxy backup"
        else
          puts "Available Codex backups (#{File.expand_path("../../.codex-shim/backups", __dir__)}):"
          list.each { |b| puts "  #{b[:short]} (build #{b[:build]})" }
  # Providers register themselves when loaded via Ask::Provider.register
      when "delete-backup"
        if rest.first == "--all"
          FileUtils.rm_rf(Codex::BACKUP_DIR)
          puts "Deleted all backups."
        elsif rest.first
          Codex.list_backups.each do |b|
            if b[:build] == rest.first
              FileUtils.rm_rf(b[:path])
              puts "Deleted backup build #{rest.first}."
      # Providers register themselves when loaded via Ask::Provider.register
    # Providers register themselves when loaded via Ask::Provider.register
        else
          puts "Usage: llm-proxy delete-backup <build> or --all"
          Codex.list_backups.each { |b| puts "  #{b[:build]}  #{b[:short]}" }
  # Providers register themselves when loaded via Ask::Provider.register
      when "-h", "--help"
        print_help
      when "-v", "--version"
        puts "llm-proxy v0.1.0"
      else
        puts "Unknown command: #{command}"
        print_help
        exit 1
# Providers register themselves when loaded via Ask::Provider.register
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
# Providers register themselves when loaded via Ask::Provider.register
    end

    def self.configure_ask
      # Ask-rb providers read their config from environment variables directly.
      # No explicit configure call needed — Ask::Agent::Chat resolves the provider
      # from the model catalog and builds the config from ENV vars.
      # Ensure required API keys are set:
      #   OPENCODE_API_KEY  — for opencode and opencode_go providers
      #   OPENROUTER_API_KEY — for openrouter provider
      #   MIMO_API_KEY / MIMO_API_BASE — for mimo provider
    end
