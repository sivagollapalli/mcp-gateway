require "json"
require "net/http"
require "openssl"
require "uri"
require "rack"

module ServerApp
  # Validates every request's bearer token on its own (defense in depth; nothing set by the
  # gateway is trusted): RS256 signature against the issuer's JWKS (cached, refetched once on an
  # unknown kid), exact `iss`, `aud` exactly this server's audience, exp/nbf, and per-tool scopes
  # for tools/call. Fails closed.
  class JwtAuth
    ALGS = %w[RS256].freeze
    BEARER = /\ABearer ([A-Za-z0-9\-._~+\/]+=*)\z/i
    MAX_TOKEN = 8192
    MAX_BODY = 1_048_576

    class Invalid < StandardError; end
    class Forbidden < StandardError
      attr_reader :scope
      def initialize(scope) = (@scope = scope; super("insufficient_scope"))
    end

    # issuer:       exact `iss` (e.g. http://localhost:8080/realms/mcp)
    # audience:     exact `aud` (e.g. mcp-orders)
    # tool_scopes:  { "tool_name" => "scope" }; a tool missing from the map cannot be called
    # fetch_base:   optional origin to fetch discovery/JWKS from (e.g. http://keycloak:8080)
    def initialize(app, issuer:, audience:, tool_scopes:, leeway: 30, fetch_base: nil, min_refetch: 10, logger: $stdout,
                   clock: -> { Time.now.to_i })
      raise ArgumentError, "issuer required" if issuer.to_s.empty?
      raise ArgumentError, "audience required" if audience.to_s.empty?
      @app = app
      @issuer = issuer
      @audience = audience
      @tool_scopes = tool_scopes.transform_keys(&:to_s).freeze
      @leeway = leeway
      @fetch_base = fetch_base&.chomp("/")
      @min_refetch = min_refetch
      @logger = logger
      @clock = clock
      @keys = {}
      @mutex = Mutex.new
      @last_refetch = nil
      @jwks_uri = nil
    end

    # Fetch discovery + JWKS up front; raises if Keycloak is unreachable (refuse to start).
    def load!
      doc = get_json(fetch_url("#{@issuer}/.well-known/openid-configuration"))
      raise "discovery issuer #{doc['issuer'].inspect} != #{@issuer.inspect}" unless doc["issuer"] == @issuer
      @jwks_uri = doc.fetch("jwks_uri")
      refresh_keys!
      raise "JWKS has no usable RS256 keys" if @keys.empty?
      self
    end

    def call(env)
      return @app.call(env) if env["PATH_INFO"] == "/up"

      claims = authenticate!(env)
      authorize!(env, claims)
      env["mcp.auth"] = { "sub" => claims["sub"], "scopes" => scopes_of(claims), "jti" => claims["jti"] }.freeze
      log("ok sub=#{claims['sub']} jti=#{claims['jti']}")
      @app.call(env)
    rescue Forbidden => e
      log("insufficient_scope required=#{e.scope}")
      deny(403, %(Bearer error="insufficient_scope", scope="#{e.scope}"), "Forbidden: insufficient scope")
    rescue Invalid => e
      log("invalid_token reason=#{e.message}")
      deny(401, 'Bearer error="invalid_token"', "Unauthorized")
    end

    private

    def authenticate!(env)
      token = env["HTTP_AUTHORIZATION"].to_s[BEARER, 1]
      raise Invalid, "missing bearer token" unless token && token.bytesize <= MAX_TOKEN
      parts = token.split(".", -1)
      raise Invalid, "malformed token" unless parts.size == 3

      header = decode_json(parts[0])
      raise Invalid, "alg not allowed" unless ALGS.include?(header["alg"])
      raise Invalid, "crit not supported" if header.key?("crit")
      kid = header["kid"]
      raise Invalid, "missing kid" unless kid.is_a?(String) && !kid.empty?
      key = key_for(kid) or raise Invalid, "unknown kid"
      sig = b64(parts[2])
      ok = key.verify(OpenSSL::Digest.new("SHA256"), sig, "#{parts[0]}.#{parts[1]}") rescue false
      raise Invalid, "bad signature" unless ok

      claims = decode_json(parts[1])
      raise Invalid, "iss mismatch" unless claims["iss"].is_a?(String) && claims["iss"] == @issuer
      aud = claims["aud"].is_a?(Array) ? claims["aud"] : [ claims["aud"] ]
      raise Invalid, "aud is not exactly #{@audience}" unless aud == [ @audience ] # rejects gateway/other-server tokens
      now = @clock.call
      raise Invalid, "missing exp" unless claims["exp"].is_a?(Numeric)
      raise Invalid, "expired" if now > claims["exp"] + @leeway
      raise Invalid, "not yet valid" if claims.key?("nbf") && (!claims["nbf"].is_a?(Numeric) || now + @leeway < claims["nbf"])
      raise Invalid, "missing sub" unless claims["sub"].is_a?(String) && !claims["sub"].empty?
      claims
    end

    # Per-tool scopes for every tools/call in the body (single message or batch).
    def authorize!(env, claims)
      return unless env["REQUEST_METHOD"] == "POST"
      input = env["rack.input"]
      return unless input
      raw = input.read(MAX_BODY + 1).to_s
      input.rewind if input.respond_to?(:rewind)
      raise Forbidden, "" if raw.bytesize > MAX_BODY
      msg = JSON.parse(raw) rescue nil
      granted = scopes_of(claims)
      Array(msg.is_a?(Array) ? msg : [ msg ]).each do |m|
        next unless m.is_a?(Hash) && m["method"] == "tools/call"
        tool = m.dig("params", "name").to_s
        required = @tool_scopes[tool]
        raise Forbidden, "" unless required # unknown tool: no scope mapping means no access
        raise Forbidden, required unless granted.include?(required)
      end
    end

    def scopes_of(claims) = claims["scope"].is_a?(String) ? claims["scope"].split : []

    def deny(status, challenge, message)
      body = JSON.generate(jsonrpc: "2.0", id: nil, error: { code: -32001, message: message })
      [ status, { "content-type" => "application/json", "www-authenticate" => challenge }, [ body ] ]
    end

    def key_for(kid)
      return @keys[kid] if @keys[kid]
      return nil if @jwks_uri.nil?
      @mutex.synchronize do
        return @keys[kid] if @keys[kid]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if @last_refetch && now - @last_refetch < @min_refetch
        @last_refetch = now
        begin
          refresh_keys!
        rescue StandardError => e
          log("JWKS refetch failed: #{e.class}")
        end
      end
      @keys[kid]
    end

    def refresh_keys!
      jwks = get_json(fetch_url(@jwks_uri))
      keys = {}
      Array(jwks["keys"]).each do |jwk|
        next unless jwk.is_a?(Hash) && jwk["kty"] == "RSA" && jwk["kid"].is_a?(String)
        next if (jwk["use"] && jwk["use"] != "sig") || (jwk["alg"] && !ALGS.include?(jwk["alg"]))
        keys[jwk["kid"]] = rsa(jwk)
      rescue ArgumentError, OpenSSL::OpenSSLError
        next
      end
      raise "JWKS has no usable RS256 keys" if keys.empty?
      @keys = keys.freeze
    end

    def rsa(jwk)
      n = OpenSSL::BN.new(self.class.b64url_decode(jwk.fetch("n")), 2)
      e = OpenSSL::BN.new(self.class.b64url_decode(jwk.fetch("e")), 2)
      raise ArgumentError, "key too short" if n.num_bits < 2048
      seq = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::ObjectId("rsaEncryption"), OpenSSL::ASN1::Null(nil) ]),
        OpenSSL::ASN1::BitString(OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::Integer(n), OpenSSL::ASN1::Integer(e) ]).to_der)
      ])
      OpenSSL::PKey::RSA.new(seq.to_der)
    rescue KeyError
      raise ArgumentError, "JWK missing n/e"
    end

    def fetch_url(url)
      return url unless @fetch_base
      origin = url[%r{\Ahttps?://[^/]+}]
      issuer_origin = @issuer[%r{\Ahttps?://[^/]+}]
      origin == issuer_origin ? "#{@fetch_base}#{url.delete_prefix(origin)}" : url
    end

    def get_json(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = 5
      res = http.request(Net::HTTP::Get.new(uri))
      raise "GET #{url} returned HTTP #{res.code}" unless res.is_a?(Net::HTTPOK)
      JSON.parse(res.body)
    end

    def b64(s)
      self.class.b64url_decode(s)
    rescue ArgumentError
      raise Invalid, "bad base64"
    end

    # Strict base64url (no padding required) without the base64 gem.
    def self.b64url_decode(s)
      raise ArgumentError, "invalid base64url" unless s.is_a?(String) && s.match?(/\A[A-Za-z0-9_-]*\z/)
      std = s.tr("-_", "+/")
      std += "=" * ((4 - std.length % 4) % 4)
      std.unpack1("m0")
    end

    def decode_json(s)
      obj = JSON.parse(b64(s))
      raise Invalid, "not a JSON object" unless obj.is_a?(Hash)
      obj
    rescue JSON::ParserError
      raise Invalid, "not JSON"
    end

    # Tokens are never logged; sub and jti only.
    def log(msg) = @logger&.puts("[jwt-auth #{@audience}] #{msg}")
  end
end
