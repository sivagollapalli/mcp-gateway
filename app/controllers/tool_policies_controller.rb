class ToolPoliciesController < ApplicationController
  def toggle
    @server = McpServer.find(params[:mcp_server_id])
    @tool = @server.tools.find { |t| t["name"] == params[:tool_name] }
    return head :not_found unless @tool

    policy = @server.tool_policies.find_or_initialize_by(tool_name: @tool["name"])
    policy.enabled = !policy.enabled if policy.persisted?
    policy.enabled = false if policy.new_record?
    policy.save!
    @enabled = policy.enabled
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @server, status: :see_other }
    end
  end
end
