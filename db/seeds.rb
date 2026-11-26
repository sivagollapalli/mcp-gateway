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
