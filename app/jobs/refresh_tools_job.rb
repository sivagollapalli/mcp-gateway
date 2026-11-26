class RefreshToolsJob < ApplicationJob
  queue_as :default

  # With an id: refresh that server. Without: refresh every enabled server.
  def perform(server_id = nil)
    scope = server_id ? McpServer.where(id: server_id) : McpServer.enabled
    scope.find_each { |server| server.refresh_tools! if server.enabled? }
  end
end
