module GatewayAuthentication
  extend ActiveSupport::Concern

  BEARER = /\ABearer ([A-Za-z0-9\-._~+\/]+=*)\z/i

  private

  # Entry point used by the MCP controllers. OIDC mode (KEYCLOAK_ISSUER set) accepts only
  # Keycloak JWTs; otherwise the legacy static gateway tokens apply.
  def authenticate_gateway_token!
    Oidc.enabled? ? authenticate_oidc! : authenticate_static_token!
  end

  # Scopes the current request needs. Controllers override.
  def required_scopes = [ "mcp:read" ]

  def authenticate_oidc!
    token = request.authorization.to_s[BEARER, 1]
    return oidc_challenge(:unauthorized) unless token # missing or non-bearer scheme

    @principal = Oidc.verifier.verify!(token, required_scopes: required_scopes)
    # Never log the token itself; sub and jti only.
    Rails.logger.info("[oidc] authenticated sub=#{@principal.sub} jti=#{@principal.jti}")
  rescue Oidc::InsufficientScope => e
    Rails.logger.warn("[oidc] insufficient_scope required=#{e.required.join(' ')}")
    oidc_challenge(:forbidden, error: "insufficient_scope", scope: e.required.join(" "))
  rescue Oidc::InvalidToken => e
    Rails.logger.warn("[oidc] invalid_token reason=#{e.message}")
    oidc_challenge(:unauthorized, error: "invalid_token")
  end

  def oidc_challenge(status, error: nil, scope: nil)
    params = []
    params << %(error="#{error}") if error
    params << %(scope="#{scope || Oidc::Config::SUPPORTED_SCOPES.first}")
    params << %(resource_metadata="#{Oidc.config.resource_metadata_url}")
    response.set_header("WWW-Authenticate", "Bearer #{params.join(', ')}")
    message = status == :forbidden ? "Forbidden: insufficient scope" : "Unauthorized: missing or invalid bearer token"
    render json: GatewayRpc.error_body(nil, -32001, message), status: status
  end

  def authenticate_static_token!
    plaintext = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
    @gateway_token = GatewayToken.authenticate(plaintext)
    return if @gateway_token

    response.set_header("WWW-Authenticate", 'Bearer realm="mcp-gateway"')
    render json: GatewayRpc.error_body(nil, -32001, "Unauthorized: missing or invalid bearer token"), status: :unauthorized
  end
end
