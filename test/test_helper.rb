ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

WebMock.disable_net_connect!

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    setup do
      Rails.cache.clear
      # Pretend every hostname resolves to a public address (no real DNS in tests).
      UpstreamMcp.resolver = ->(_host) { [ "93.184.216.34" ] }
      Rails.configuration.x.gateway.allow_private_upstreams = false
    end

    def create_server(name: "alpha", url: "https://alpha.example.com/mcp", **attrs)
      McpServer.create!({ name: name, url: url }.merge(attrs))
    end

    TOOL_A = { "name" => "echo", "description" => "Echo", "inputSchema" => { "type" => "object" } }.freeze
    TOOL_B = { "name" => "add", "description" => "Add", "inputSchema" => { "type" => "object" } }.freeze

    # Server with a fresh tool cache so no upstream traffic is attempted.
    def create_server_with_tools(name: "alpha", tools: [ TOOL_A, TOOL_B ], **attrs)
      server = create_server(name: name, url: "https://#{name}.example.com/mcp", **attrs)
      server.update_columns(tools_cache: tools, tools_count: tools.size, last_status: "ok", last_checked_at: Time.current)
      ToolCatalog.bump!
      server
    end

    # --- upstream stubbing ---------------------------------------------------
    def rpc_json(id, result: nil, error: nil)
      body = { jsonrpc: "2.0", id: id }
      error ? body[:error] = error : body[:result] = result
      body.to_json
    end

    def stub_upstream(url, tools: [ TOOL_A, TOOL_B ], call_result: nil)
      stub_request(:delete, url).to_return(status: 204)
      stub_request(:post, url).to_return do |req|
        msg = ::JSON.parse(req.body)
        case msg["method"]
        when "initialize"
          { status: 200, headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "sess-1" },
            body: rpc_json(msg["id"], result: { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "x" } }) }
        when "notifications/initialized" then { status: 202, body: "" }
        when "tools/list" then { status: 200, headers: { "Content-Type" => "application/json" }, body: rpc_json(msg["id"], result: { tools: tools }) }
        when "tools/call"
          { status: 200, headers: { "Content-Type" => "application/json" },
            body: rpc_json(msg["id"], result: call_result || { content: [ { type: "text", text: "pong" } ], isError: false }) }
        end
      end
    end
  end
end

class ActionDispatch::IntegrationTest
  def mcp_post(body, token: nil, raw: false)
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{token}" if token
    post "/mcp", params: raw ? body : body.to_json, headers: headers
  end

  def rpc(method, params = nil, id: 1, token:)
    msg = { jsonrpc: "2.0", id: id, method: method }
    msg[:params] = params if params
    mcp_post(msg, token: token)
    response.parsed_body
  end

  def sign_in(user = nil)
    user ||= User.create!(email: "admin@example.com", password: "password123")
    post session_path, params: { email: user.email, password: "password123" }
  end
end
