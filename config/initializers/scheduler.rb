# Minimal in-process scheduler: refresh every server's tool list every 5 minutes.
# Runs only inside a web server process (or when MCP_SCHEDULER=1).
Rails.application.config.after_initialize do
  next if Rails.env.test?
  next unless defined?(Rails::Server) || ENV["MCP_SCHEDULER"] == "1"
  next if ENV["MCP_SCHEDULER"] == "0"

  interval = Integer(ENV.fetch("MCP_REFRESH_INTERVAL", 300))
  Thread.new do
    Thread.current.name = "mcp-refresh-scheduler"
    sleep 5
    loop do
      begin
        RefreshToolsJob.perform_later
      rescue => e
        Rails.logger.error("[mcp-gateway] scheduler error: #{e.class}: #{e.message}")
      end
      sleep interval
    end
  end
end
