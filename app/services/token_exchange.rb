require "net/http"
require "openssl"

# RFC 8693 token exchange for upstream MCP servers whose auth_type is "token_exchange".
#
# The inbound user token never leaves the gateway except as `subject_token` to the token
# exchange server. Upstreams only ever see a token whose `aud` is exactly their audience.
module TokenExchange
  GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange"
  ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token"
  EXPIRY_MARGIN = 30 # seconds: never use a cached token in its last 30s
  TIMEOUT = 5
  MAX_BODY = 262_144

  class Error < StandardError; end
  class ConfigurationError < Error; end

  # Non-200 from the token endpoint. Carries the OAuth error code (never the body or tokens).
  class ExchangeFailed < Error
    attr_reader :status, :oauth_error

    def initialize(status, oauth_error)
      @status = status
      @oauth_error = oauth_error
      super("token endpoint returned HTTP #{status}#{" (#{oauth_error})" if oauth_error}")
    end
  end

  # The token endpoint answered 200 but the token fails our outbound checks.
  class InvalidIssuedToken < Error; end

  # Wraps a bearer token so it cannot leak through #inspect, #to_s or logging.
  class Secret
    def initialize(value) = @value = value.to_s.dup.freeze
    def value = @value
    def to_s = "[FILTERED]"
    def inspect = "#<TokenExchange::Secret [FILTERED]>"
    def digest = OpenSSL::Digest::SHA256.hexdigest(@value)
  end

  Issued = Struct.new(:access_token, :expires_at, keyword_init: true) do
    def inspect = "#<TokenExchange::Issued expires_at=#{expires_at}>"
    alias_method :to_s, :inspect
  end

  class << self
    # Exchanges the caller's (already validated) token for one scoped to the server's audience
    # and the tool's scope. Returns the access token string.
    def exchange_for_tool(server, subject_token, tool_name)
      raise ConfigurationError, "server #{server.name} is not configured for token exchange" unless server.token_exchange?
      raise ConfigurationError, "no scope configured for tool #{tool_name}" unless server.required_scope_for(tool_name)

      scopes = server.exchange_scopes_for(tool_name)
      key = cache_key("x", server, subject_token.digest, scopes)
      fetch_cached(key, server) do
        client_for(server).exchange(subject_token.value, audience: server.exchange_audience, scope: scopes.join(" "))
      end
    end

    # Client-credentials token for tools/list discovery (no user involved). It carries only the
    # always-requested scopes, so it cannot be used to call tools that require a tool scope.
    def discovery_token(server)
      key = cache_key("cc", server, "", server.discovery_scopes)
      fetch_cached(key, server) do
        client_for(server).client_credentials(audience: server.exchange_audience, scope: server.discovery_scopes.join(" "))
      end
    end

    def cache
      @cache ||= ActiveSupport::Cache::MemoryStore.new(size: 16.megabytes) # process-local: tokens never hit disk/DB
    end

    def reset!
      @cache = nil
      @metadata = nil
    end

    def metadata_cache
      @metadata ||= Concurrent::Map.new
    end

    private

    def client_for(server)
      secret = server.effective_exchange_client_secret
      raise ConfigurationError, "no client secret for #{server.name} (set GATEWAY_CLIENT_SECRET)" if secret.blank?
      Client.new(issuer: server.effective_exchange_issuer, client_id: server.effective_exchange_client_id, client_secret: secret)
    end

    def cache_key(kind, server, subject_digest, scopes)
      material = [ kind, server.effective_exchange_issuer, server.effective_exchange_client_id, server.exchange_audience,
                   scopes.sort.join(" "), subject_digest ].join("\n")
      "tx:#{OpenSSL::Digest::SHA256.hexdigest(material)}"
    end

    def fetch_cached(key, server)
      cached = cache.read(key)
      return cached.access_token if cached && cached.expires_at - EXPIRY_MARGIN > Time.now.to_i

      issued = yield
      ttl = [ issued.expires_at - Time.now.to_i - EXPIRY_MARGIN, Rails.configuration.x.gateway.exchange_ttl ].min
      cache.write(key, issued, expires_in: ttl) if ttl.positive? # never cached beyond expiry
      issued.access_token
    end
  end

  # One token exchange server (OIDC issuer) + client credentials.
  class Client
    def initialize(issuer:, client_id:, client_secret:)
      @issuer = issuer
      @client_id = client_id
      @client_secret = client_secret
    end

    def exchange(subject_token, audience:, scope:)
      form = {
        grant_type: GRANT_TYPE,
        subject_token: subject_token,
        subject_token_type: ACCESS_TOKEN_TYPE,
        requested_token_type: ACCESS_TOKEN_TYPE,
        audience: audience,
        scope: scope
      }
      body = post(form)
      if body.key?("issued_token_type") && body["issued_token_type"] != ACCESS_TOKEN_TYPE
        raise InvalidIssuedToken, "unexpected issued_token_type"
      end
      issued(body, audience: audience, scope: scope)
    end

    def client_credentials(audience:, scope:)
      issued(post({ grant_type: "client_credentials", scope: scope }), audience: audience, scope: scope)
    end

    private

    def issued(body, audience:, scope:)
      token = body["access_token"]
      raise InvalidIssuedToken, "no access_token in response" unless token.is_a?(String) && !token.empty?
      raise InvalidIssuedToken, "token_type is not Bearer" unless body["token_type"].to_s.casecmp?("bearer")

      claims = decode_claims(token)
      exp = verify_claims!(claims, audience: audience, scope: scope)
      expires_in = body["expires_in"]
      expires_at = expires_in.is_a?(Integer) && expires_in.positive? ? [ Time.now.to_i + expires_in, exp ].min : exp
      Issued.new(access_token: token, expires_at: expires_at)
    end

    # Outbound checks before the token may be forwarded. The token came straight from the
    # token endpoint over an authenticated request, so we decode rather than re-verify the signature;
    # the upstream verifies the signature itself.
    def verify_claims!(claims, audience:, scope:)
      raise InvalidIssuedToken, "iss mismatch" unless claims["iss"].is_a?(String) && claims["iss"] == metadata["issuer"]

      aud = claims["aud"]
      auds = aud.is_a?(Array) ? aud : [ aud ]
      raise InvalidIssuedToken, "aud is not exactly #{audience}" unless auds == [ audience ]

      exp = claims["exp"]
      raise InvalidIssuedToken, "missing or past exp" unless exp.is_a?(Integer) && exp > Time.now.to_i
      raise InvalidIssuedToken, "missing sub" unless claims["sub"].is_a?(String) && !claims["sub"].empty?

      granted = claims["scope"].is_a?(String) ? claims["scope"].split : []
      missing = scope.split - granted
      raise InvalidIssuedToken, "issued token lacks scope #{missing.join(' ')}" if missing.any?
      exp
    end

    def decode_claims(token)
      parts = token.split(".")
      raise InvalidIssuedToken, "issued token is not a JWT" unless parts.size == 3
      header = JSON.parse(Base64.urlsafe_decode64(parts[0]))
      raise InvalidIssuedToken, "issued token alg not allowed" unless Oidc::Config::ALLOWED_ALGS.include?(header["alg"])
      claims = JSON.parse(Base64.urlsafe_decode64(parts[1]))
      raise InvalidIssuedToken, "issued token payload is not an object" unless claims.is_a?(Hash)
      claims
    rescue ArgumentError, JSON::ParserError
      raise InvalidIssuedToken, "issued token is malformed"
    end

    def metadata
      TokenExchange.metadata_cache.compute_if_absent(@issuer) { discover }
    end

    def discover
      doc = JSON.parse(http(:get, "#{@issuer}/.well-known/openid-configuration").body)
      raise ConfigurationError, "discovery issuer mismatch for #{@issuer}" unless doc.is_a?(Hash) && doc["issuer"] == @issuer
      unless doc["token_endpoint"].is_a?(String) && McpServer.secure_url?(doc["token_endpoint"])
        raise ConfigurationError, "token_endpoint missing or not https"
      end
      doc.slice("issuer", "token_endpoint").freeze
    rescue JSON::ParserError
      raise ConfigurationError, "discovery document for #{@issuer} is not JSON"
    end

    def post(form)
      res = http(:post, metadata["token_endpoint"], form, allow_error: true)
      unless res.is_a?(Net::HTTPOK)
        oauth_error = (JSON.parse(res.body)["error"] rescue nil)
        oauth_error = nil unless oauth_error.is_a?(String) && oauth_error.match?(/\A[\w.\-]{1,64}\z/)
        # Keycloak's error body holds an error code and description, no tokens. Debug level only.
        Rails.logger.debug { "[token-exchange] HTTP #{res.code} body=#{res.body.to_s[0, 500]}" }
        Rails.logger.warn("[token-exchange] failed client=#{@client_id} status=#{res.code} error=#{oauth_error || '-'}")
        raise ExchangeFailed.new(res.code.to_i, oauth_error)
      end
      body = JSON.parse(res.body)
      raise InvalidIssuedToken, "token response is not an object" unless body.is_a?(Hash)
      body
    rescue JSON::ParserError
      raise InvalidIssuedToken, "token response is not JSON"
    end

    def http(verb, url, form = nil, allow_error: false)
      raise ConfigurationError, "refusing insecure URL #{url}" unless McpServer.secure_url?(url)
      uri = URI.parse(Oidc.config.fetch_url(url))
      conn = Net::HTTP.new(uri.host, uri.port)
      conn.use_ssl = uri.scheme == "https"
      conn.open_timeout = conn.read_timeout = TIMEOUT
      req = verb == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"
      if form
        req.basic_auth(form_encode(@client_id), form_encode(@client_secret)) # client_secret_basic (RFC 6749 2.3.1)
        req.set_form_data(form)
      end
      res = conn.request(req)
      raise Error, "response from #{uri.host} too large" if res.body.to_s.bytesize > MAX_BODY
      raise Error, "GET #{url} returned HTTP #{res.code}" unless allow_error || res.is_a?(Net::HTTPOK)
      res
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "token exchange server unreachable: #{e.class}"
    end

    def form_encode(value) = URI.encode_www_form_component(value)
  end
end
