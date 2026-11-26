class ToolPolicy < ApplicationRecord
  belongs_to :mcp_server
  validates :tool_name, presence: true, uniqueness: { scope: :mcp_server_id }
  after_commit { ToolCatalog.bump! }
end
