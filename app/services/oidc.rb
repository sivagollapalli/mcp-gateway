# User-leg authentication: validates Keycloak-issued JWT access tokens locally
# against a cached JWKS. See README "OIDC authentication".
module Oidc
  class Error < StandardError; end
  class ConfigurationError < Error; end

  # Crypto/claims failure -> 401 invalid_token. The message is for logs only and never contains the token.
  class InvalidToken < Error; end

  # Token is valid but lacks scopes -> 403 insufficient_scope.
  class InsufficientScope < Error
    attr_reader :required

    def initialize(required)
      @required = required
      super("missing scope")
    end
  end

  Principal = Struct.new(:sub, :scopes, :jti, keyword_init: true)

  class << self
    attr_writer :config, :provider

    def config
      @config ||= Config.from_env
    end

    def enabled?
      config.enabled?
    end

    def provider
      @provider ||= Provider.new(config)
    end

    def verifier
      TokenVerifier.new(config: config, provider: provider)
    end

    # Fetches discovery + JWKS. Raises ConfigurationError (callers refuse to boot).
    def boot!
      return unless enabled?
      config.validate!
      provider.load!
      Rails.logger.info("[oidc] ready issuer=#{config.issuer} audience=#{config.audience} keys=#{provider.key_ids.size}")
    end

    # Gateway scopes plus the tool scopes of enabled token-exchange upstreams, so MCP clients
    # request them at login (each must exist as a client scope in the realm).
    def scopes_supported
      tool_scopes = McpServer.enabled.where(auth_type: "token_exchange").flat_map(&:all_tool_scopes)
      (Config::SUPPORTED_SCOPES + tool_scopes.sort).uniq
    end

    def reset!
      @config = @provider = nil
    end
  end
end
