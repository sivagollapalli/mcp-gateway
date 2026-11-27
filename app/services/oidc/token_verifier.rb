require "openssl"

module Oidc
  # Implements the validation pipeline: header (kid, alg only) -> pinned alg -> kid lookup
  # -> signature -> claims -> scopes. Pure local verification; no calls to Keycloak.
  class TokenVerifier
    MAX_TOKEN_BYTES = 8192
    B64URL = /\A[A-Za-z0-9_-]+\z/

    def initialize(config:, provider:, clock: -> { Time.now.to_i })
      @config = config
      @provider = provider
      @clock = clock
    end

    # Returns a Principal, or raises InvalidToken / InsufficientScope.
    def verify!(token, required_scopes: [])
      parts = split(token)
      header = decode_json(parts[0], "header")

      # Only kid and alg are read from the header. alg is checked against the pinned allowlist.
      alg = header["alg"]
      kid = header["kid"]
      raise InvalidToken, "alg not allowed" unless alg.is_a?(String) && Config::ALLOWED_ALGS.include?(alg)
      raise InvalidToken, "unsupported critical header" if header.key?("crit")
      raise InvalidToken, "missing kid" unless kid.is_a?(String) && !kid.empty?

      key = @provider.key_for(kid)
      raise InvalidToken, "unknown kid" unless key

      verify_signature!(key, "#{parts[0]}.#{parts[1]}", parts[2])

      claims = decode_json(parts[1], "payload")
      verify_claims!(claims)
      scopes = claims["scope"].is_a?(String) ? claims["scope"].split(" ").uniq : []
      missing = Array(required_scopes) - scopes
      raise InsufficientScope.new(Array(required_scopes)) if missing.any?

      Principal.new(sub: claims["sub"], scopes: scopes, jti: claims["jti"])
    end

    private

    def split(token)
      raise InvalidToken, "malformed token" unless token.is_a?(String) && token.bytesize <= MAX_TOKEN_BYTES
      parts = token.split(".", -1)
      raise InvalidToken, "malformed token" unless parts.size == 3 && parts[0, 2].all? { _1.match?(B64URL) } && parts[2].match?(/\A[A-Za-z0-9_-]*\z/)
      parts
    end

    def b64(segment)
      Base64.urlsafe_decode64(segment)
    rescue ArgumentError
      raise InvalidToken, "bad base64"
    end

    def decode_json(segment, what)
      obj = JSON.parse(b64(segment))
      raise InvalidToken, "#{what} is not an object" unless obj.is_a?(Hash)
      obj
    rescue JSON::ParserError
      raise InvalidToken, "#{what} is not JSON"
    end

    def verify_signature!(key, signing_input, signature_segment)
      ok = key.verify(OpenSSL::Digest.new("SHA256"), b64(signature_segment), signing_input)
      raise InvalidToken, "bad signature" unless ok
    rescue OpenSSL::PKey::PKeyError
      raise InvalidToken, "bad signature"
    end

    def verify_claims!(claims)
      raise InvalidToken, "iss mismatch" unless claims["iss"].is_a?(String) && claims["iss"] == @config.issuer

      aud = claims["aud"]
      auds = aud.is_a?(Array) ? aud : [ aud ]
      raise InvalidToken, "aud mismatch" unless auds.any? { |a| a.is_a?(String) && a == @config.audience }

      now = @clock.call
      leeway = @config.leeway
      exp = claims["exp"]
      raise InvalidToken, "missing exp" unless exp.is_a?(Numeric)
      raise InvalidToken, "expired" if now > exp + leeway
      if claims.key?("nbf")
        nbf = claims["nbf"]
        raise InvalidToken, "bad nbf" unless nbf.is_a?(Numeric)
        raise InvalidToken, "not yet valid" if now + leeway < nbf
      end
      raise InvalidToken, "missing sub" unless claims["sub"].is_a?(String) && !claims["sub"].empty?
      raise InvalidToken, "missing jti" unless claims["jti"].is_a?(String) && !claims["jti"].empty?
    end
  end
end
