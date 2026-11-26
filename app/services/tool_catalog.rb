# Aggregates tools across enabled upstream servers and maps gateway tool names
# (<server>__<tool>) back to servers.
module ToolCatalog
  SEPARATOR = "__"
  MAX_NAME = 64
  VERSION_KEY = "mcp_gateway/tools_version"

  module_function

  # --- naming -------------------------------------------------------------

  def encode_name(server_name, tool_name)
    tool = tool_name.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
    full = "#{server_name}#{SEPARATOR}#{tool}"
    return full if full.length <= MAX_NAME && tool == tool_name.to_s

    suffix = Digest::SHA256.hexdigest("#{server_name}#{SEPARATOR}#{tool_name}")[0, 6]
    room = MAX_NAME - server_name.length - SEPARATOR.length - suffix.length - 1
    base = tool[0, [ room, 1 ].max]
    "#{server_name}#{SEPARATOR}#{base}_#{suffix}"[0, MAX_NAME]
  end

  # Splits on the first "__". Server names never contain "__".
  def split_name(full_name)
    server, tool = full_name.to_s.split(SEPARATOR, 2)
    return nil if server.blank? || tool.blank?
    [ server, tool ]
  end

  # --- tool hygiene -------------------------------------------------------

  def sanitize_tool(tool)
    max = Rails.configuration.x.gateway.max_description_chars
    tool = tool.to_h.stringify_keys
    out = { "name" => tool["name"].to_s,
            "description" => tool["description"].to_s.truncate(max, omission: "…"),
            "inputSchema" => tool["inputSchema"].is_a?(Hash) ? tool["inputSchema"] : { "type" => "object" } }
    out["title"] = tool["title"].to_s.truncate(200) if tool["title"].present?
    out["annotations"] = tool["annotations"] if tool["annotations"].is_a?(Hash)
    out["outputSchema"] = tool["outputSchema"] if tool["outputSchema"].is_a?(Hash)
    out
  end

  def digest(tools) = Digest::SHA256.hexdigest(JSON.generate(Array(tools)))

  # --- cache version ------------------------------------------------------

  def version = Rails.cache.fetch(VERSION_KEY) { SecureRandom.hex(4) }
  # Invalidates the aggregated list and tells connected MCP clients to re-fetch it.
  def bump!
    Rails.cache.write(VERSION_KEY, SecureRandom.hex(8))
    ToolsChangedBroadcaster.broadcast
  end

  # --- aggregation --------------------------------------------------------

  # Tools exposed to MCP clients (prefixed, policy filtered).
  def tools
    refresh_stale!
    Rails.cache.fetch("mcp_gateway/tools/#{version}", expires_in: Rails.configuration.x.gateway.tools_ttl.seconds) { build }
  end

  def build
    disabled = ToolPolicy.where(enabled: false).pluck(:mcp_server_id, :tool_name).to_set
    McpServer.enabled.where(last_status: %w[ok unknown]).order(:name).flat_map do |server|
      server.tools.filter_map do |t|
        next if disabled.include?([ server.id, t["name"] ])
        t.merge("name" => encode_name(server.name, t["name"]))
      end
    end
  end

  # Refresh servers whose tool list is older than the TTL (or never fetched).
  # A failing upstream is logged and skipped; refresh! stamps last_checked_at either way,
  # so a broken server is retried at most once per TTL.
  def refresh_stale!
    ttl = Rails.configuration.x.gateway.tools_ttl.seconds
    McpServer.enabled.where("last_checked_at IS NULL OR last_checked_at < ?", ttl.ago).find_each do |server|
      server.refresh_tools!
    rescue => e
      Rails.logger.error("[mcp-gateway] stale refresh crashed server=#{server.name}: #{e.class}: #{e.message}")
    end
  end

  # Returns [server, tool_hash] or nil. Tool must exist upstream (per cache).
  def resolve(full_name)
    server_name, = split_name(full_name)
    return nil unless server_name
    server = McpServer.enabled.find_by(name: server_name)
    return nil unless server
    tool = server.tools.find { |t| encode_name(server.name, t["name"]) == full_name }
    tool ? [ server, tool ] : nil
  end
end
