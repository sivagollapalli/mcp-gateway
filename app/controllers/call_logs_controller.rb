class CallLogsController < ApplicationController
  def index
    scope = CallLog.includes(:mcp_server, :gateway_token).recent
    scope = scope.where(mcp_server_id: params[:server_id]) if params[:server_id].present?
    scope = scope.where(status: params[:status]) if CallLog::STATUSES.include?(params[:status])
    @logs, @page, @total_pages = paginate(scope)
    @servers = McpServer.order(:name)
  end
end
