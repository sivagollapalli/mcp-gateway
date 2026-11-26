class McpController < ActionController::API
  include GatewayAuthentication
  before_action :authenticate_gateway_token!, only: :create

  def create
    result = GatewayRpc.new(gateway_token: @gateway_token).handle(request.raw_post)
    if result.body.nil?
      head :accepted
    else
      render json: result.body, status: result.status
    end
  end
end
