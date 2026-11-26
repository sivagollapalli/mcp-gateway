class McpServer < ApplicationRecord
  AUTH_TYPES = %w[none bearer header].freeze
  TRANSPORTS = %w[http].freeze
  STATUSES = %w[ok error unknown].freeze

  encrypts :auth_token

  has_many :tool_policies, dependent: :destroy
  has_many :call_logs, dependent: :nullify

  validates :name, presence: true, uniqueness: true, length: { maximum: 32 },
                   format: { with: /\A[a-z0-9_]+\z/, message: "may only contain lowercase letters, digits and underscores" }
  validate :name_has_no_double_underscore
  validates :url, presence: true
  validate :url_is_http
  validates :transport, inclusion: { in: TRANSPORTS }
  validates :auth_type, inclusion: { in: AUTH_TYPES }
  validates :last_status, inclusion: { in: STATUSES }
  validates :auth_token, presence: true, if: -> { auth_type != "none" }
  validates :description, length: { maximum: 2000 }

  scope :enabled, -> { where(enabled: true) }

  after_commit :after_change, on: [ :create, :update ]
  after_commit -> { ToolCatalog.bump! }, on: :destroy

  def tools = Array(tools_cache)

  def disabled_tool_names
    tool_policies.where(enabled: false).pluck(:tool_name)
  end

  def tool_enabled?(tool_name)
    !tool_policies.exists?(tool_name: tool_name, enabled: false)
  end

  # Connects upstream and stores the tool list. Returns true/false; never raises
  # for upstream problems (they are recorded in last_error).
  def refresh_tools!
    fresh = UpstreamMcp.new(self).list_tools.map { |t| ToolCatalog.sanitize_tool(t) }
    changed = ToolCatalog.digest(fresh) != ToolCatalog.digest(tools_cache) || last_status != "ok"
    update_columns(tools_cache: fresh, tools_count: fresh.size, last_status: "ok",
                   last_error: nil, last_checked_at: Time.current)
    ToolCatalog.bump! if changed
    true
  rescue UpstreamMcp::Error => e
    Rails.logger.warn("[mcp-gateway] refresh failed server=#{name} #{e.class}: #{e.message}")
    changed = last_status != "error"
    update_columns(last_status: "error", last_error: e.message.to_s.truncate(1000), last_checked_at: Time.current)
    ToolCatalog.bump! if changed
    false
  end

  private

  RELEVANT = %w[url transport auth_type auth_token enabled].freeze

  def after_change
    ToolCatalog.bump!
    if saved_change_to_id? || (saved_changes.keys & RELEVANT).any?
      RefreshToolsJob.perform_later(id) if enabled?
    end
  end

  def name_has_no_double_underscore
    errors.add(:name, "must not contain two consecutive underscores") if name.to_s.include?("__")
  end

  def url_is_http
    return if url.blank?
    uri = URI.parse(url)
    errors.add(:url, "must be an http(s) URL with a host") unless uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    errors.add(:url, "is not a valid URL")
  end
end
