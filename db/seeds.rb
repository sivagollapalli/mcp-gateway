# Admin user from ENV (dev defaults only outside production).
email = ENV["ADMIN_EMAIL"].presence || (Rails.env.production? ? nil : "admin@example.com")
password = ENV["ADMIN_PASSWORD"].presence || (Rails.env.production? ? nil : "changeme123")

if email && password
  admin = User.find_or_initialize_by(email: email.strip.downcase)
  admin.password = password if admin.new_record? || ENV["ADMIN_PASSWORD"].present?
  admin.save!
  puts "Admin user ready: #{admin.email}"
else
  puts "Set ADMIN_EMAIL and ADMIN_PASSWORD to seed the admin user."
end

# Example upstream (disabled). Point it at script/mock_mcp_server.rb to try the gateway:
#   ruby script/mock_mcp_server.rb   # listens on :9292
McpServer.find_or_create_by!(name: "example") do |s|
  s.url = "http://localhost:9292/mcp"
  s.description = "Example entry for the bundled mock server (script/mock_mcp_server.rb). Enable it and set ALLOW_PRIVATE_UPSTREAMS=true."
  s.enabled = false
end

# Token-exchange demo upstreams (docker compose sets SEED_TOKEN_EXCHANGE_DEMO=1).
# Each entry is the whole "route": audience + scopes. Adding a server needs only another entry
# (or the same fields in the admin UI) plus the matching Keycloak client and client scopes.
if ENV["SEED_TOKEN_EXCHANGE_DEMO"] == "1"
  [
    { name: "orders", url: ENV.fetch("ORDERS_MCP_URL", "http://localhost:9301/mcp"),
      exchange_audience: "mcp-orders", exchange_scope: "mcp-orders-audience", default_tool_scope: "orders:read",
      tool_scopes: { "create_order" => "orders:write", "update_order" => "orders:write" },
      description: "Sample orders server (mcp_servers/orders). Called with exchanged tokens, aud=mcp-orders." },
    { name: "payments", url: ENV.fetch("PAYMENTS_MCP_URL", "http://localhost:9302/mcp"),
      exchange_audience: "mcp-payments", exchange_scope: "mcp-payments-audience", default_tool_scope: "payments:refund",
      tool_scopes: {},
      description: "Sample payments server (mcp_servers/payments). Called with exchanged tokens, aud=mcp-payments." }
  ].each do |attrs|
    server = McpServer.find_or_initialize_by(name: attrs[:name])
    server.assign_attributes(attrs.merge(auth_type: "token_exchange", enabled: true))
    server.save!
    puts "Token-exchange server ready: #{server.name} -> #{server.url} (aud #{server.exchange_audience})"
  end
end
