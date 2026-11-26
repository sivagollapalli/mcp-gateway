class CallLog < ApplicationRecord
  belongs_to :mcp_server, optional: true
  belongs_to :gateway_token, optional: true

  STATUSES = %w[ok error].freeze
  scope :recent, -> { order(created_at: :desc, id: :desc) }
end
