#!/usr/bin/env ruby
# Tiny mock MCP server (Streamable HTTP) for local verification.
#   ruby script/mock_mcp_server.rb [port]      # default 9292
#   MOCK_TOKEN=secret   require "Authorization: Bearer secret"
#   MOCK_SSE=1          answer tools/call with text/event-stream
# Tools: echo, add, and "many_N" paging via nextCursor.
require "json"
require "securerandom"
require "rack"
require "rackup"

class MockMcp
  TOOLS = [
    { name: "echo", description: "Echo back the given text",
      inputSchema: { type: "object", properties: { text: { type: "string" } }, required: [ "text" ] } },
    { name: "add", description: "Add two numbers",
      inputSchema: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: %w[a b] } },
    { name: "fail", description: "Always returns isError", inputSchema: { type: "object" } }
  ].freeze

  def initialize
    @sessions = {}
  end

  def call(env)
    req = Rack::Request.new(env)
    return [ 405, { "allow" => "POST" }, [ "" ] ] unless req.post?

    if (token = ENV["MOCK_TOKEN"]) && env["HTTP_AUTHORIZATION"] != "Bearer #{token}"
      return [ 401, {}, [ "unauthorized" ] ]
    end

    msg = JSON.parse(req.body.read)
    method = msg["method"]
    sid = env["HTTP_MCP_SESSION_ID"]
    return [ 202, {}, [] ] unless msg.key?("id")

    headers = { "content-type" => "application/json" }
    if method == "initialize"
      sid = SecureRandom.uuid
      @sessions[sid] = true
      headers["mcp-session-id"] = sid
      return reply(headers, msg, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "mock", version: "0.1" } })
    end
    return [ 404, {}, [ "session not found" ] ] unless @sessions[sid]

    case method
    when "tools/list"
      cursor = msg.dig("params", "cursor")
      if cursor.nil?
        reply(headers, msg, result: { tools: TOOLS.first(2), nextCursor: "page2" })
      else
        reply(headers, msg, result: { tools: TOOLS.last(1) })
      end
    when "tools/call"
      args = msg.dig("params", "arguments") || {}
      result = case msg.dig("params", "name")
      when "echo" then { content: [ { type: "text", text: args["text"].to_s } ], isError: false }
      when "add" then { content: [ { type: "text", text: (args["a"].to_f + args["b"].to_f).to_s } ], isError: false }
      else { content: [ { type: "text", text: "boom" } ], isError: true }
      end
      reply(headers, msg, result: result, sse: ENV["MOCK_SSE"] == "1")
    else
      reply(headers, msg, error: { code: -32601, message: "Method not found" })
    end
  end

  private

  def reply(headers, msg, result: nil, error: nil, sse: false)
    body = { jsonrpc: "2.0", id: msg["id"] }
    error ? body[:error] = error : body[:result] = result
    if sse
      headers = headers.merge("content-type" => "text/event-stream")
      [ 200, headers, [ "event: message\ndata: #{JSON.generate(body)}\n\n" ] ]
    else
      [ 200, headers, [ JSON.generate(body) ] ]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  port = (ARGV[0] || 9292).to_i
  puts "Mock MCP server on http://localhost:#{port}/mcp"
  Rackup::Server.start(app: MockMcp.new, Port: port, Host: "127.0.0.1", server: ENV.fetch("MOCK_SERVER", "puma"))
end
