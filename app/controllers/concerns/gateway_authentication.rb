module GatewayAuthentication
  extend ActiveSupport::Concern

  private

  def authenticate_gateway_token!
    plaintext = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
    @gateway_token = GatewayToken.authenticate(plaintext)
    return if @gateway_token

    response.set_header("WWW-Authenticate", 'Bearer realm="mcp-gateway"')
    render json: GatewayRpc.error_body(nil, -32001, "Unauthorized: missing or invalid bearer token"), status: :unauthorized
  end
end
