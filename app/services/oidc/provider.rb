require "net/http"
require "openssl"

module Oidc
  # Holds the OIDC discovery document and the JWKS cache (indexed by kid).
  # The only network calls happen at boot and on a kid miss; never per request otherwise.
  class Provider
    MAX_BODY = 1_048_576
    TIMEOUT = 5

    attr_reader :metadata

    def initialize(config)
      @config = config
      @keys = {}.freeze
      @metadata = nil
      @mutex = Mutex.new
      @last_refetch = nil
    end

    def load!
      @metadata = fetch_discovery!
      refresh_keys!
      raise ConfigurationError, "JWKS at #{@metadata['jwks_uri']} contains no usable RS256 signing keys" if @keys.empty?
      self
    end

    def key_ids = @keys.keys

    # Resolves a kid. On a miss, refetches the JWKS once (rate limited so unknown kids
    # cannot be used to hammer Keycloak) and resolves again. Fails closed: nil when unknown.
    def key_for(kid)
      key = @keys[kid]
      return key if key
      return nil unless @metadata && refetch_allowed? # never loaded => fail closed

      @mutex.synchronize do
        return @keys[kid] if @keys[kid] # another thread refreshed meanwhile
        @last_refetch = monotonic_now
        begin
          refresh_keys!
        rescue Error => e
          Rails.logger.warn("[oidc] JWKS refetch failed: #{e.message}")
        end
      end
      @keys[kid]
    end

    private

    def refetch_allowed?
      @last_refetch.nil? || (monotonic_now - @last_refetch) >= @config.jwks_min_refetch_interval
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def fetch_discovery!
      doc = get_json(@config.discovery_url)
      raise ConfigurationError, "discovery document is not a JSON object" unless doc.is_a?(Hash)
      # Byte-exact issuer match: a mismatch means tokens could never validate (or the wrong IdP answered).
      unless doc["issuer"] == @config.issuer
        raise ConfigurationError, "discovery issuer #{doc['issuer'].inspect} != KEYCLOAK_ISSUER #{@config.issuer.inspect}"
      end
      %w[authorization_endpoint token_endpoint registration_endpoint jwks_uri].each do |k|
        raise ConfigurationError, "discovery document lacks #{k}" unless doc[k].is_a?(String) && doc[k].present?
      end
      doc
    end

    def refresh_keys!
      jwks = get_json(@config.fetch_url(@metadata.fetch("jwks_uri")))
      raise ConfigurationError, "JWKS is not a JSON object with keys" unless jwks.is_a?(Hash) && jwks["keys"].is_a?(Array)
      keys = {}
      jwks["keys"].each do |jwk|
        next unless jwk.is_a?(Hash) && jwk["kty"] == "RSA" && jwk["kid"].is_a?(String)
        next if jwk["use"] && jwk["use"] != "sig"
        next if jwk["alg"] && !Config::ALLOWED_ALGS.include?(jwk["alg"])
        keys[jwk["kid"]] = rsa_key(jwk)
      rescue ArgumentError, OpenSSL::OpenSSLError
        Rails.logger.warn("[oidc] skipping unusable JWK kid=#{jwk['kid'].inspect}")
      end
      raise ConfigurationError, "JWKS contains no usable RS256 signing keys" if keys.empty?
      @keys = keys.freeze # atomic swap
    end

    def rsa_key(jwk)
      n = OpenSSL::BN.new(Base64.urlsafe_decode64(jwk.fetch("n")), 2)
      e = OpenSSL::BN.new(Base64.urlsafe_decode64(jwk.fetch("e")), 2)
      raise ArgumentError, "RSA key shorter than 2048 bits" if n.num_bits < 2048
      seq = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::ObjectId("rsaEncryption"), OpenSSL::ASN1::Null(nil) ]),
        OpenSSL::ASN1::BitString(OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::Integer(n), OpenSSL::ASN1::Integer(e) ]).to_der)
      ])
      OpenSSL::PKey::RSA.new(seq.to_der)
    rescue KeyError
      raise ArgumentError, "JWK missing n/e"
    end

    def get_json(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = TIMEOUT
      res = http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
      raise ConfigurationError, "GET #{url} returned HTTP #{res.code}" unless res.is_a?(Net::HTTPOK)
      raise ConfigurationError, "GET #{url} response too large" if res.body.to_s.bytesize > MAX_BODY
      JSON.parse(res.body)
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, URI::InvalidURIError, JSON::ParserError => e
      raise ConfigurationError, "GET #{url} failed: #{e.class}: #{e.message}"
    end
  end
end
