class DashboardController < ApplicationController
  def show
    @servers_count = McpServer.count
    @enabled_servers = McpServer.enabled.count
    @tools_count = McpServer.enabled.sum(:tools_count)
    @calls_24h = CallLog.where(created_at: 24.hours.ago..).count
    @errors_24h = CallLog.where(created_at: 24.hours.ago.., status: "error").count
    @recent_errors = CallLog.where(status: "error").includes(:mcp_server).recent.limit(10)
    @failing_servers = McpServer.where(last_status: "error").order(:name)
  end
end
