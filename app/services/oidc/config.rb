module Oidc
  class Config
    # Pinned. Never derived from the token header.
    ALLOWED_ALGS = %w[RS256].freeze
    SUPPORTED_SCOPES = %w[mcp:read mcp:tools:execute].freeze
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

    attr_reader :issuer, :audience, :leeway, :public_url, :internal_url, :jwks_min_refetch_interval

    def self.from_env(env = ENV)
      new(
        issuer: env["KEYCLOAK_ISSUER"],
        audience: env.fetch("GATEWAY_AUDIENCE", "mcp-gateway"),
        leeway: env.fetch("CLOCK_LEEWAY", "30"),
        public_url: env["GATEWAY_PUBLIC_URL"],
        internal_url: env["KEYCLOAK_INTERNAL_URL"],
        jwks_min_refetch_interval: env.fetch("JWKS_MIN_REFETCH_INTERVAL", "10")
      )
    end

    def initialize(issuer: nil, audience: "mcp-gateway", leeway: 30, public_url: nil, internal_url: nil, jwks_min_refetch_interval: 10)
      @issuer = issuer.presence
      @audience = audience.to_s
      @leeway = Integer(leeway)
      @public_url = public_url.presence&.chomp("/")
      @internal_url = internal_url.presence&.chomp("/")
      @jwks_min_refetch_interval = Integer(jwks_min_refetch_interval)
    rescue ArgumentError, TypeError => e
      raise ConfigurationError, "invalid numeric setting: #{e.message}"
    end

    # OIDC mode is on when KEYCLOAK_ISSUER is set. Otherwise the legacy static gateway tokens apply.
    def enabled? = issuer.present?

    def validate!
      raise ConfigurationError, "KEYCLOAK_ISSUER is required" unless enabled?
      raise ConfigurationError, "KEYCLOAK_ISSUER must not end with '/'" if issuer.end_with?("/")
      raise ConfigurationError, "GATEWAY_AUDIENCE must not be blank" if audience.blank?
      raise ConfigurationError, "CLOCK_LEEWAY must be between 0 and 300" unless (0..300).cover?(leeway)
      raise ConfigurationError, "GATEWAY_PUBLIC_URL is required (e.g. http://localhost:8081)" if public_url.blank?
      [ [ "KEYCLOAK_ISSUER", issuer ], [ "GATEWAY_PUBLIC_URL", public_url ], [ "KEYCLOAK_INTERNAL_URL", internal_url ] ].each do |name, value|
        next if value.blank?
        uri = URI.parse(value) rescue raise(ConfigurationError, "#{name} is not a valid URL")
        raise ConfigurationError, "#{name} must be an http(s) URL" unless %w[http https].include?(uri.scheme) && uri.host
        next if uri.scheme == "https" || LOCAL_HOSTS.include?(uri.host) || name == "KEYCLOAK_INTERNAL_URL"
        raise ConfigurationError, "#{name} must use https (plain http is allowed only for localhost)"
      end
      true
    end

    def resource_url = "#{public_url}/mcp"
    def resource_metadata_url = "#{public_url}/.well-known/oauth-protected-resource"

    # The discovery/JWKS fetch may go through a different (container-internal) origin,
    # e.g. KEYCLOAK_INTERNAL_URL=http://keycloak:8080 replaces http://localhost:8080.
    # Only the fetch URL is rewritten; the advertised endpoints stay verbatim.
    def fetch_url(url)
      origin = issuer_origin
      return url unless internal_url && origin && url.start_with?("#{origin}/")
      "#{internal_url}#{url.delete_prefix(origin)}"
    end

    def issuer_origin
      uri = URI.parse(issuer)
      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
    rescue URI::InvalidURIError
      nil
    end

    def discovery_url = fetch_url("#{issuer}/.well-known/openid-configuration")
  end
end
