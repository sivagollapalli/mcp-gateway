class McpController < ActionController::API
  include GatewayAuthentication
  # Runs before any MCP/JSON-RPC handling.
  before_action :authenticate_gateway_token!, only: :create

  def create
    result = GatewayRpc.new(gateway_token: @gateway_token, principal: @principal).handle(request.raw_post)
    if result.body.nil?
      head :accepted
    else
      render json: result.body, status: result.status
    end
  end

  private

  # Every request needs mcp:read; executing a tool additionally needs mcp:tools:execute.
  def required_scopes
    scopes = [ "mcp:read" ]
    msg = JSON.parse(request.raw_post) rescue nil
    scopes << "mcp:tools:execute" if msg.is_a?(Hash) && msg["method"] == "tools/call"
    scopes
  end
end
