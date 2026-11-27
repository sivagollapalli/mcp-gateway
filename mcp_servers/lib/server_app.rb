require "json"
require "mcp"
require "mcp/server/transports/streamable_http_transport"
require_relative "jwt_auth"

# Wraps an MCP::Server as a Rack app (Streamable HTTP, SDK default stateful sessions) with a
# /up health check and either OAuth JWT validation (OIDC_ISSUER + OIDC_AUDIENCE, see JwtAuth)
# or the legacy static bearer (MCP_TOKEN).
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

  # tool_scopes: { "tool_name" => "required scope" } enforced when OIDC_ISSUER is set.
  def self.build(name:, tools:, instructions: nil, stateless: ENV["MCP_STATELESS"] == "1", tool_scopes: {}, env: ENV)
    server = MCP::Server.new(name: name, version: "1.0.0", instructions: instructions, tools: tools)
    # ALLOWED_HOSTS: extra Host header values beyond loopback (the SDK's DNS-rebinding guard),
    # e.g. the compose service name.
    allowed_hosts = env["ALLOWED_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?)
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: stateless, allowed_hosts: allowed_hosts)
    server.transport = transport

    mcp_app = ->(env) { transport.call(env) }
    app = lambda do |env|
      case env["PATH_INFO"]
      when "/up" then [200, { "content-type" => "text/plain" }, ["ok"]]
      when "/mcp" then mcp_app.call(env)
      else [404, { "content-type" => "text/plain" }, ["Not found. MCP endpoint is /mcp"]]
      end
    end
    return BearerAuth.new(app, env["MCP_TOKEN"]) if env["OIDC_ISSUER"].to_s.empty?

    audience = env["OIDC_AUDIENCE"].to_s
    abort "#{name}: OIDC_AUDIENCE is required when OIDC_ISSUER is set" if audience.empty?
    missing = tools.map(&:name_value) - tool_scopes.keys.map(&:to_s)
    abort "#{name}: no scope configured for tool(s) #{missing.join(', ')}" if missing.any?
    auth = JwtAuth.new(app, issuer: env["OIDC_ISSUER"], audience: audience, tool_scopes: tool_scopes,
                            leeway: Integer(env.fetch("CLOCK_LEEWAY", "30")), fetch_base: env["OIDC_INTERNAL_URL"])
    begin
      auth.load!
    rescue StandardError => e
      abort "#{name}: refusing to start, cannot load issuer metadata/JWKS: #{e.message}"
    end
    puts "#{name}: validating tokens iss=#{env['OIDC_ISSUER']} aud=#{audience}"
    auth
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
