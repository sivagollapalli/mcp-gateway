require "test_helper"

class McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @token_record, @token = GatewayToken.generate!(name: "t")
  end

  test "rejects missing and invalid bearer tokens with a JSON-RPC 401" do
    mcp_post({ jsonrpc: "2.0", id: 1, method: "ping" })
    assert_response :unauthorized
    assert_equal(-32001, response.parsed_body.dig("error", "code"))
    assert_equal "application/json", response.media_type

    mcp_post({ jsonrpc: "2.0", id: 1, method: "ping" }, token: "wrong")
    assert_response :unauthorized
  end

  test "rejects revoked tokens" do
    @token_record.revoke!
    mcp_post({ jsonrpc: "2.0", id: 1, method: "ping" }, token: @token)
    assert_response :unauthorized
  end

  test "stores only a digest and records last_used_at" do
    assert_equal GatewayToken.digest(@token), @token_record.token_digest
    assert_not_includes @token_record.attributes.values.map(&:to_s), @token
    rpc("ping", token: @token)
    assert_not_nil @token_record.reload.last_used_at
  end

  test "initialize advertises tools capability" do
    body = rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "c", version: "1" } }, token: @token)
    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal({ "tools" => { "listChanged" => true } }, body.dig("result", "capabilities"))
    assert_equal "mcp-gateway", body.dig("result", "serverInfo", "name")
    assert_equal 1, body["id"]
  end

  test "ping returns empty result" do
    assert_equal({}, rpc("ping", token: @token)["result"])
  end

  test "notifications return 202 with empty body" do
    mcp_post({ jsonrpc: "2.0", method: "notifications/initialized" }, token: @token)
    assert_response :accepted
    assert_empty response.body
  end

  test "unknown method returns -32601" do
    assert_equal(-32601, rpc("resources/list", token: @token).dig("error", "code"))
  end

  test "malformed JSON returns -32700 and non-object returns -32600" do
    mcp_post("{nope", token: @token, raw: true)
    assert_equal(-32700, response.parsed_body.dig("error", "code"))
    mcp_post("[1,2]", token: @token, raw: true)
    assert_equal(-32600, response.parsed_body.dig("error", "code"))
  end

  test "tools/call with bad params returns -32602" do
    assert_equal(-32602, rpc("tools/call", {}, token: @token).dig("error", "code"))
    assert_equal(-32602, rpc("tools/call", { name: "nope__x" }, token: @token).dig("error", "code"))
    assert_equal(-32602, rpc("tools/call", { name: "nodelimiter" }, token: @token).dig("error", "code"))
    assert_equal(-32602, rpc("tools/call", { name: "a__b", arguments: "str" }, token: @token).dig("error", "code"))
  end

  test "tools/list aggregates prefixed tools and honors policies" do
    server = create_server_with_tools
    server.tool_policies.create!(tool_name: "add", enabled: false)
    body = rpc("tools/list", token: @token)
    assert_equal [ "alpha__echo" ], body.dig("result", "tools").map { _1["name"] }
  end

  test "tools/call proxies to upstream and returns the result as is, with a call log" do
    server = create_server_with_tools
    stub_upstream(server.url, call_result: { content: [ { type: "text", text: "hi" } ], isError: false, structuredContent: { a: 1 } })
    body = rpc("tools/call", { name: "alpha__echo", arguments: { text: "hi" } }, token: @token)
    assert_equal "hi", body.dig("result", "content", 0, "text")
    assert_equal({ "a" => 1 }, body.dig("result", "structuredContent"))
    assert_requested(:post, server.url) do |r|
      m = ::JSON.parse(r.body)
      m["method"] == "tools/call" && m.dig("params", "name") == "echo" && m.dig("params", "arguments") == { "text" => "hi" }
    end
    log = CallLog.last
    assert_equal [ "ok", "echo", server.id, @token_record.id ], [ log.status, log.tool_name, log.mcp_server_id, log.gateway_token_id ]
  end

  test "tools/call on a disabled tool is rejected without hitting upstream" do
    server = create_server_with_tools
    server.tool_policies.create!(tool_name: "echo", enabled: false)
    assert_equal(-32602, rpc("tools/call", { name: "alpha__echo" }, token: @token).dig("error", "code"))
    assert_not_requested(:post, server.url)
  end

  test "tools/call on a disabled server is rejected" do
    create_server_with_tools(enabled: false)
    assert_equal(-32602, rpc("tools/call", { name: "alpha__echo" }, token: @token).dig("error", "code"))
  end

  test "upstream failure yields isError result and an error call log" do
    server = create_server_with_tools
    stub_request(:post, server.url).to_timeout
    body = rpc("tools/call", { name: "alpha__echo", arguments: {} }, token: @token)
    assert_equal true, body.dig("result", "isError")
    assert_match(/Upstream call failed/, body.dig("result", "content", 0, "text"))
    assert_equal "error", CallLog.last.status
  end

  test "upstream isError result is passed through and logged as error" do
    server = create_server_with_tools
    stub_upstream(server.url, call_result: { content: [ { type: "text", text: "bad" } ], isError: true })
    body = rpc("tools/call", { name: "alpha__echo" }, token: @token)
    assert_equal true, body.dig("result", "isError")
    assert_equal "error", CallLog.last.status
  end

  test "oversized results are truncated" do
    server = create_server_with_tools
    Rails.configuration.x.gateway.max_result_bytes = 200
    stub_upstream(server.url, call_result: { content: [ { type: "text", text: "x" * 1000 } ] })
    text = rpc("tools/call", { name: "alpha__echo" }, token: @token).dig("result", "content", 0, "text")
    assert_operator text.bytesize, :<, 400
    assert_match(/truncated/, text)
  ensure
    Rails.configuration.x.gateway.max_result_bytes = 100_000
  end

  test "rate limiting returns 429" do
    Rack::Attack.enabled = true
    Rails.configuration.x.gateway.rate_limit = 2
    3.times { mcp_post({ jsonrpc: "2.0", id: 1, method: "ping" }, token: @token) }
    assert_response :too_many_requests
    assert_equal "application/json", response.media_type
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store.clear
    Rails.configuration.x.gateway.rate_limit = 120
  end
end
