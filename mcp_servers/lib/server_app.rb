require "json"
require "mcp"
require "mcp/server/transports/streamable_http_transport"

# Wraps an MCP::Server as a Rack app (Streamable HTTP, SDK default stateful sessions) with
# optional bearer auth (MCP_TOKEN) and a /up health check.
module ServerApp
  class BearerAuth
    def initialize(app, token)
      @app = app
      @token = token.to_s
    end

    def call(env)
      return @app.call(env) if @token.empty? || env["PATH_INFO"] == "/up"

      given = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
      if Rack::Utils.secure_compare(given, @token)
        @app.call(env)
      else
        body = JSON.generate(jsonrpc: "2.0", id: nil, error: { code: -32001, message: "Unauthorized" })
        [401, { "content-type" => "application/json" }, [body]]
      end
    end
  end

  def self.build(name:, tools:, instructions: nil, stateless: ENV["MCP_STATELESS"] == "1")
    server = MCP::Server.new(name: name, version: "1.0.0", instructions: instructions, tools: tools)
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: stateless)
    server.transport = transport

    mcp_app = ->(env) { transport.call(env) }
    app = lambda do |env|
      case env["PATH_INFO"]
      when "/up" then [200, { "content-type" => "text/plain" }, ["ok"]]
      when "/mcp" then mcp_app.call(env)
      else [404, { "content-type" => "text/plain" }, ["Not found. MCP endpoint is /mcp"]]
      end
    end
    BearerAuth.new(app, ENV["MCP_TOKEN"])
  end

  # Same as the SDK's examples/http_server.rb: serve the Rack app with Puma via Rackup.
  def self.run(app, default_port:)
    require "rackup"
    port = Integer(ENV.fetch("PORT", default_port))
    puts "MCP server listening on http://127.0.0.1:#{port}/mcp"
    Rackup::Handler.get("puma").run(app, Port: port, Host: ENV.fetch("HOST", "127.0.0.1"))
  end

  def self.text(message, error: false)
    MCP::Tool::Response.new([{ type: "text", text: message }], error: error)
  end

  def self.json(data, error: false)
    MCP::Tool::Response.new([{ type: "text", text: JSON.pretty_generate(data) }], error: error)
  end
end
