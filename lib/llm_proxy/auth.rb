require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "fileutils"

module LLMProxy
  module OAuth
    CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
    AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
    TOKEN_URL = "https://auth.openai.com/oauth/token"
    REDIRECT_URI = "http://localhost:1455/auth/callback"
    SCOPE = "openid profile email offline_access"
    JWT_CLAIM_PATH = "https://api.openai.com/auth"
    STORE_PATH = File.expand_path("../../.auth.json", __dir__)

    Credentials = Struct.new(:access_token, :refresh_token, :expires_at, :account_id, keyword_init: true) do
      def expired?
        Time.now.to_i >= (expires_at || 0)
      end

      def valid?
        access_token && !expired?
      end
    end

    class << self
      def login_url
        verifier = generate_code_verifier
        challenge = generate_code_challenge(verifier)
        state = SecureRandom.hex(16)

        store_session(verifier: verifier, state: state)

        params = {
          response_type: "code",
          client_id: CLIENT_ID,
          redirect_uri: REDIRECT_URI,
          scope: SCOPE,
          code_challenge: challenge,
          code_challenge_method: "S256",
          state: state,
          originator: "llm-proxy",
        }

        uri = URI(AUTHORIZE_URL)
        uri.query = URI.encode_www_form(params)
        uri.to_s
      end

      def handle_callback(code:, state:)
        session = load_session
        unless session && session[:state] == state
          return { error: "State mismatch — possible CSRF attack" }
        end

        unless session[:verifier]
          return { error: "No PKCE verifier found. Start a new login." }
        end

        result = exchange_code(code, session[:verifier])
        clear_session

        if result[:error]
          result
        else
          store_credentials(result)
          { success: true, account_id: result[:account_id] }
        end
      end

      def get_token
        creds = load_credentials
        return creds.access_token if creds&.valid?

        if creds&.expired?
          creds = refresh_credentials(creds)
          return creds.access_token if creds
        end

        # Fallback: try reading from Codex's auth file
        codex_path = File.expand_path("~/.codex/auth.json")
        if File.exist?(codex_path)
          data = JSON.parse(File.read(codex_path)) rescue nil
          token = data&.dig("tokens", "access_token")
          if token
            account_id = data&.dig("tokens", "account_id") || ""
            store_credentials(Credentials.new(access_token: token, account_id: account_id, expires_at: Time.now.to_i + 3600))
            return token
          end
        end

        nil
      end

      def get_account_id
        creds = load_credentials
        creds&.account_id
      end

      def logged_in?
        creds = load_credentials
        creds&.valid?
      end

      def logout
        File.delete(STORE_PATH) if File.exist?(STORE_PATH)
        true
      end

      private

      def exchange_code(code, verifier)
        uri = URI(TOKEN_URL)
        body = {
          grant_type: "authorization_code",
          code: code,
          code_verifier: verifier,
          redirect_uri: REDIRECT_URI,
          client_id: CLIENT_ID,
        }

        response = Net::HTTP.post_form(uri, body)
        data = JSON.parse(response.body) rescue {}

        unless response.code.to_i == 200
          return { error: data["error_description"] || data["error"] || "Token exchange failed (#{response.code})" }
        end

        expires_in = data["expires_in"].to_i
        account_id = extract_account_id(data["access_token"])

        {
          access_token: data["access_token"],
          refresh_token: data["refresh_token"],
          expires_at: Time.now.to_i + expires_in,
          account_id: account_id,
        }
      end

      def refresh_credentials(creds)
        uri = URI(TOKEN_URL)
        body = {
          grant_type: "refresh_token",
          refresh_token: creds.refresh_token,
          client_id: CLIENT_ID,
        }

        response = Net::HTTP.post_form(uri, body)
        data = JSON.parse(response.body) rescue {}

        unless response.code.to_i == 200
          $stderr.puts "[OAuth] Token refresh failed: #{data["error_description"] || data["error"]}"
          logout
          return nil
        end

        expires_in = data["expires_in"].to_i
        new_creds = Credentials.new(
          access_token: data["access_token"] || creds.access_token,
          refresh_token: data["refresh_token"] || creds.refresh_token,
          expires_at: Time.now.to_i + expires_in,
          account_id: creds.account_id,
        )
        store_credentials(new_creds)
        new_creds
      end

      def extract_account_id(jwt)
        payload = jwt.split(".")[1]
        raw = Base64.urlsafe_decode64(payload) rescue nil
        return nil unless raw

        claims = JSON.parse(raw) rescue {}
        claims.dig(JWT_CLAIM_PATH, "chatgpt_account_id")
      end

      def generate_code_verifier
        raw = SecureRandom.random_bytes(32)
        Base64.urlsafe_encode64(raw, padding: false)
      end

      def generate_code_challenge(verifier)
        digest = Digest::SHA256.digest(verifier)
        Base64.urlsafe_encode64(digest, padding: false)
      end

      def store_session(data)
        path = session_path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate(data))
        File.chmod(0600, path)
      end

      def load_session
        path = session_path
        return nil unless File.exist?(path)
        JSON.parse(File.read(path), symbolize_names: true)
      rescue
        nil
      end

      def clear_session
        path = session_path
        File.delete(path) if File.exist?(path)
      end

      def session_path
        File.expand_path("../../.oauth_session.json", __dir__)
      end

      def store_credentials(creds)
        creds = Credentials.new(creds) if creds.is_a?(Hash)
        FileUtils.mkdir_p(File.dirname(STORE_PATH))
        File.write(STORE_PATH, JSON.generate({
          access_token: creds.access_token,
          refresh_token: creds.refresh_token,
          expires_at: creds.expires_at,
          account_id: creds.account_id,
        }))
        File.chmod(0600, STORE_PATH)
      end

      def load_credentials
        return nil unless File.exist?(STORE_PATH)
        data = JSON.parse(File.read(STORE_PATH), symbolize_names: true)
        Credentials.new(
          access_token: data[:access_token],
          refresh_token: data[:refresh_token],
          expires_at: data[:expires_at],
          account_id: data[:account_id],
        )
      rescue
        nil
      end
    end
  end
end
