class McpServer < ApplicationRecord
  AUTH_TYPES = %w[none bearer header token_exchange].freeze
  TRANSPORTS = %w[http].freeze
  STATUSES = %w[ok error unknown].freeze
  # RFC 6749 section 3.3 scope-token, and a conservative client_id/audience format.
  SCOPE_TOKEN = /\A[\x21\x23-\x5B\x5D-\x7E]+\z/
  IDENTIFIER = /\A[A-Za-z0-9._:\-]{1,255}\z/
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  encrypts :auth_token
  encrypts :exchange_client_secret

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
  validates :auth_token, presence: true, if: -> { %w[bearer header].include?(auth_type) }
  validates :description, length: { maximum: 2000 }
  validate :token_exchange_settings, if: :token_exchange?

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

  # --- token exchange (RFC 8693) --------------------------------------------

  def token_exchange? = auth_type == "token_exchange"

  def effective_exchange_issuer = exchange_issuer.presence || Oidc.config.issuer
  def effective_exchange_client_id = exchange_client_id.presence || ENV.fetch("GATEWAY_CLIENT_ID", "mcp-gateway")
  def effective_exchange_client_secret = exchange_client_secret.presence || ENV["GATEWAY_CLIENT_SECRET"].presence

  # Scope the caller must hold (and that is requested in the exchange) for one tool.
  def required_scope_for(tool_name)
    Hash(tool_scopes)[tool_name.to_s].presence || default_tool_scope.presence
  end

  # Every tool scope this server may require (advertised in scopes_supported).
  def all_tool_scopes = ([ default_tool_scope ] + Hash(tool_scopes).values).compact_blank.uniq

  # Scopes requested at the token endpoint: the always-requested scopes plus the tool scope.
  def exchange_scopes_for(tool_name) = (exchange_scope.to_s.split + [ required_scope_for(tool_name) ]).compact_blank.uniq

  # Scopes requested for tool discovery (client credentials): only the always-requested scopes.
  def discovery_scopes = exchange_scope.to_s.split.uniq

  # Form helper: "tool=scope" per line.
  def tool_scopes_text = Hash(tool_scopes).map { |k, v| "#{k}=#{v}" }.join("\n")

  def tool_scopes_text=(text)
    @tool_scopes_text_error = nil
    pairs = text.to_s.each_line.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }.map do |line|
      tool, scope = line.split("=", 2).map { _1.to_s.strip }
      @tool_scopes_text_error = "has an invalid line #{line.inspect} (expected tool_name=scope)" if tool.blank? || scope.blank?
      [ tool, scope ]
    end
    self.tool_scopes = pairs.to_h
  end

  # Connects upstream and stores the tool list. Returns true/false; never raises
  # for upstream problems (they are recorded in last_error).
  def refresh_tools!
    bearer = token_exchange? ? TokenExchange.discovery_token(self) : nil
    fresh = UpstreamMcp.new(self, bearer_token: bearer).list_tools.map { |t| ToolCatalog.sanitize_tool(t) }
    changed = ToolCatalog.digest(fresh) != ToolCatalog.digest(tools_cache) || last_status != "ok"
    update_columns(tools_cache: fresh, tools_count: fresh.size, last_status: "ok",
                   last_error: nil, last_checked_at: Time.current)
    ToolCatalog.bump! if changed
    true
  rescue UpstreamMcp::Error, TokenExchange::Error => e
    Rails.logger.warn("[mcp-gateway] refresh failed server=#{name} #{e.class}: #{e.message}")
    changed = last_status != "error"
    update_columns(last_status: "error", last_error: e.message.to_s.truncate(1000), last_checked_at: Time.current)
    ToolCatalog.bump! if changed
    false
  end

  def self.insecure_http_allowed? = Rails.configuration.x.gateway.allow_insecure_http

  # Plain http is only acceptable for localhost, or when ALLOW_INSECURE_HTTP is set (development only).
  def self.secure_url?(url)
    uri = URI.parse(url.to_s)
    return false unless uri.is_a?(URI::HTTP) && uri.host.present?
    uri.scheme == "https" || LOCAL_HOSTS.include?(uri.host.delete_prefix("[").delete_suffix("]")) || insecure_http_allowed?
  rescue URI::InvalidURIError
    false
  end

  private

  RELEVANT = %w[url transport auth_type auth_token enabled exchange_issuer exchange_client_id exchange_client_secret
                exchange_audience exchange_scope].freeze

  def after_change
    ToolCatalog.bump!
    if saved_change_to_id? || (saved_changes.keys & RELEVANT).any?
      RefreshToolsJob.perform_later(id) if enabled?
    end
  end

  def token_exchange_settings
    errors.add(:tool_scopes, @tool_scopes_text_error) if @tool_scopes_text_error
    errors.add(:url, "must use https (http only for localhost or with ALLOW_INSECURE_HTTP)") unless self.class.secure_url?(url)

    issuer = effective_exchange_issuer
    if issuer.blank?
      errors.add(:exchange_issuer, "is required (or set KEYCLOAK_ISSUER)")
    elsif issuer.end_with?("/") || !self.class.secure_url?(issuer)
      errors.add(:exchange_issuer, "must be an https URL without a trailing slash (http only for localhost or with ALLOW_INSECURE_HTTP)")
    end
    errors.add(:exchange_client_id, "is invalid") unless effective_exchange_client_id.match?(IDENTIFIER)
    errors.add(:exchange_client_secret, "is required (or set GATEWAY_CLIENT_SECRET)") if effective_exchange_client_secret.blank?
    errors.add(:exchange_audience, "is required and may contain only letters, digits and . _ : -") unless exchange_audience.to_s.match?(IDENTIFIER)
    if exchange_audience.present? && exchange_audience == Oidc.config.audience
      errors.add(:exchange_audience, "must not be the gateway's own audience")
    end
    # Fail closed: every tool must map to a scope.
    errors.add(:default_tool_scope, "is required for token exchange") if default_tool_scope.blank?

    scopes = exchange_scope.to_s.split + [ default_tool_scope ].compact_blank + Hash(tool_scopes).values
    bad = scopes.reject { _1.to_s.match?(SCOPE_TOKEN) }
    errors.add(:base, "Invalid scope value(s): #{bad.join(', ')}") if bad.any?
    bad_tools = Hash(tool_scopes).keys.reject { _1.to_s.match?(/\A[A-Za-z0-9_.\-\/]{1,128}\z/) }
    errors.add(:tool_scopes, "has invalid tool name(s): #{bad_tools.join(', ')}") if bad_tools.any?
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
