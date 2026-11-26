class ConnectController < ApplicationController
  def show
    @mcp_url = "#{request.base_url}/mcp"
    @tokens = GatewayToken.active.order(:name)
  end
end
