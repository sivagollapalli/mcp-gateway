class McpController < ActionController::API
  include GatewayAuthentication
  # Runs before any MCP/JSON-RPC handling.
  before_action :authenticate_gateway_token!, only: :create

  def create
    result = GatewayRpc.new(gateway_token: @gateway_token, principal: @principal, subject_token: @subject_token)
                       .handle(request.raw_post)
    if result.body.nil?
      head :accepted
    else
      render json: result.body, status: result.status
    end
  end

  private

  # Every request needs mcp:read; executing a tool also needs mcp:tools:execute and, for
  # token-exchange upstreams, the tool's own scope (so a missing scope is a 403 with a
  # WWW-Authenticate challenge naming it, before anything is exchanged or proxied).
  def required_scopes
    scopes = [ "mcp:read" ]
    msg = JSON.parse(request.raw_post) rescue nil
    return scopes unless msg.is_a?(Hash) && msg["method"] == "tools/call"

    scopes << "mcp:tools:execute"
    name = msg.dig("params", "name")
    server, tool = ToolCatalog.resolve(name) if name.is_a?(String)
    scopes << server.required_scope_for(tool["name"]) if server&.token_exchange? && server.required_scope_for(tool["name"])
    scopes.uniq
  end
end
