require "minitest/autorun"
require "openssl"
require "json"
require "rack"
require "rack/mock"
require "stringio"
require_relative "../lib/jwt_auth"

class JwtAuthTest < Minitest::Test
  ISSUER = "http://localhost:8080/realms/mcp".freeze
  AUD = "mcp-orders".freeze
  SCOPES = { "get_order" => "orders:read", "create_order" => "orders:write" }.freeze
  KEY = OpenSSL::PKey::RSA.generate(2048)
  OTHER_KEY = OpenSSL::PKey::RSA.generate(2048)

  def b64(s) = [ s ].pack("m0").tr("+/", "-_").delete("=")

  def jwk(key, kid) = { "kty" => "RSA", "kid" => kid, "use" => "sig", "alg" => "RS256", "n" => b64(key.n.to_s(2)), "e" => b64(key.e.to_s(2)) }

  def token(claims = {}, key: KEY, kid: "k1", alg: "RS256")
    now = Time.now.to_i
    c = { "iss" => ISSUER, "aud" => AUD, "sub" => "user-1", "jti" => "j1", "exp" => now + 300, "iat" => now,
          "scope" => "mcp-orders-audience orders:read" }.merge(claims).compact
    input = "#{b64({ alg: alg, kid: kid, typ: 'JWT' }.to_json)}.#{b64(c.to_json)}"
    "#{input}.#{b64(alg == 'RS256' ? key.sign(OpenSSL::Digest.new('SHA256'), input) : '')}"
  end

  # JwtAuth with the network replaced by an in-memory JWKS.
  class TestAuth < ServerApp::JwtAuth
    attr_accessor :jwks, :fetches
    def get_json(url)
      self.fetches = (fetches || 0) + 1 if url.end_with?("/certs")
      return { "issuer" => ISSUER, "jwks_uri" => "#{ISSUER}/protocol/openid-connect/certs" } if url.include?("openid-configuration")
      { "keys" => jwks }
    end
  end

  def setup
    @inner_calls = []
    inner = ->(env) { @inner_calls << env; [ 200, { "content-type" => "application/json" }, [ "{}" ] ] }
    @log = StringIO.new
    @auth = TestAuth.new(inner, issuer: ISSUER, audience: AUD, tool_scopes: SCOPES, min_refetch: 0, logger: @log)
    @auth.jwks = [ jwk(KEY, "k1") ]
    @auth.load!
  end

  def post(tok, body = { jsonrpc: "2.0", id: 1, method: "tools/list" })
    headers = { "CONTENT_TYPE" => "application/json", input: body.to_json }
    headers["HTTP_AUTHORIZATION"] = "Bearer #{tok}" if tok
    Rack::MockRequest.new(@auth).post("/mcp", headers)
  end

  def call_tool(tok, name) = post(tok, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: {} } })

  def test_valid_token_passes_and_exposes_sub
    res = post(token)
    assert_equal 200, res.status
    assert_equal "user-1", @inner_calls.last["mcp.auth"]["sub"]
  end

  def test_health_check_is_open
    assert_equal 200, Rack::MockRequest.new(@auth).get("/up").status
  end

  def test_missing_and_malformed_tokens_are_401
    [ nil, "abc", "a.b.c" ].each do |t|
      res = post(t)
      assert_equal 401, res.status, t.inspect
      assert_equal 'Bearer error="invalid_token"', res.headers["www-authenticate"]
    end
    assert_empty @inner_calls
  end

  def test_rejects_tokens_for_the_gateway_or_another_server
    [ "mcp-gateway", "mcp-payments", [ "mcp-orders", "mcp-gateway" ], [], nil ].each do |aud|
      assert_equal 401, post(token({ "aud" => aud })).status, aud.inspect
    end
  end

  def test_accepts_aud_as_single_element_array
    assert_equal 200, post(token({ "aud" => [ AUD ] })).status
  end

  def test_rejects_wrong_issuer_expired_and_future_tokens
    assert_equal 401, post(token({ "iss" => "#{ISSUER}/" })).status
    assert_equal 401, post(token({ "exp" => Time.now.to_i - 60 })).status
    assert_equal 401, post(token({ "nbf" => Time.now.to_i + 120 })).status
    assert_equal 200, post(token({ "exp" => Time.now.to_i - 10 })).status # within 30s leeway
  end

  def test_rejects_bad_signature_and_disallowed_alg
    assert_equal 401, post(token(key: OTHER_KEY)).status
    assert_equal 401, post(token(alg: "none")).status
  end

  def test_unknown_kid_refetches_jwks_once
    @auth.jwks = [ jwk(KEY, "k1"), jwk(OTHER_KEY, "k2") ]
    before = @auth.fetches
    assert_equal 200, post(token(key: OTHER_KEY, kid: "k2")).status
    assert_equal before + 1, @auth.fetches
    assert_equal 401, post(token(kid: "nope")).status
  end

  def test_per_tool_scopes_are_enforced
    assert_equal 200, call_tool(token, "get_order").status
    res = call_tool(token, "create_order")
    assert_equal 403, res.status
    assert_equal 'Bearer error="insufficient_scope", scope="orders:write"', res.headers["www-authenticate"]
    assert_equal 200, call_tool(token({ "scope" => "orders:write" }), "create_order").status
  end

  def test_unmapped_tool_is_forbidden
    assert_equal 403, call_tool(token({ "scope" => "orders:read orders:write" }), "drop_table").status
  end

  def test_batches_are_checked_per_message
    batch = [ { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_order" } },
              { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "create_order" } } ]
    assert_equal 403, post(token, batch).status
  end

  def test_gateway_injected_identity_headers_are_ignored
    req = { "CONTENT_TYPE" => "application/json", "HTTP_X_USER" => "admin", "HTTP_X_SCOPES" => "orders:write",
            input: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "create_order" } }.to_json,
            "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    assert_equal 403, Rack::MockRequest.new(@auth).post("/mcp", req).status
  end

  def test_body_is_still_readable_downstream
    call_tool(token, "get_order")
    assert_includes @inner_calls.last["rack.input"].read, "get_order"
  end

  def test_logs_never_contain_the_token
    t = token
    post(t)
    post(t.sub(/.\z/, "x"))
    refute_includes @log.string, t.split(".")[2]
    assert_includes @log.string, "sub=user-1"
  end

  def test_refuses_to_start_without_keys
    auth = TestAuth.new(->(_) {}, issuer: ISSUER, audience: AUD, tool_scopes: SCOPES)
    auth.jwks = []
    assert_raises(RuntimeError) { auth.load! }
  end
end
