require "test_helper"

class UpstreamMcpTest < ActiveSupport::TestCase
  URL = "https://alpha.example.com/mcp".freeze
  JSON_CT = { "Content-Type" => "application/json" }.freeze

  setup { @server = create_server(url: URL) }

  test "performs initialize handshake, sends session id and auth headers, lists tools" do
    @server.update!(auth_type: "bearer", auth_token: "s3cret")
    stub_upstream(URL)
    tools = UpstreamMcp.new(@server).list_tools
    assert_equal %w[echo add], tools.map { _1["name"] }

    assert_requested(:post, URL, times: 1) do |r|
      m = ::JSON.parse(r.body)
      m["method"] == "initialize" && r.headers["Authorization"] == "Bearer s3cret" &&
        r.headers["Accept"] == "application/json, text/event-stream" && r.headers["Content-Type"] == "application/json" &&
        m.dig("params", "protocolVersion") == "2025-06-18"
    end
    assert_requested(:post, URL, times: 1) { |r| ::JSON.parse(r.body)["method"] == "notifications/initialized" && r.headers["Mcp-Session-Id"] == "sess-1" }
    assert_requested(:post, URL, times: 1) { |r| ::JSON.parse(r.body)["method"] == "tools/list" && r.headers["Mcp-Session-Id"] == "sess-1" }
  end

  test "custom header auth sends the configured header" do
    @server.update!(auth_type: "header", auth_token: "X-Api-Key: abc")
    stub_upstream(URL)
    UpstreamMcp.new(@server).list_tools
    assert_requested(:post, URL, at_least_times: 1) { |r| r.headers["X-Api-Key"] == "abc" }
  end

  test "follows nextCursor pagination" do
    stub_request(:post, URL).to_return do |req|
      msg = ::JSON.parse(req.body)
      case msg["method"]
      when "initialize" then { body: rpc_json(msg["id"], result: {}), headers: JSON_CT }
      when "notifications/initialized" then { status: 202 }
      when "tools/list"
        if msg.dig("params", "cursor") == "c2"
          { body: rpc_json(msg["id"], result: { tools: [ TOOL_B ] }), headers: JSON_CT }
        else
          { body: rpc_json(msg["id"], result: { tools: [ TOOL_A ], nextCursor: "c2" }), headers: JSON_CT }
        end
      end
    end
    assert_equal %w[echo add], UpstreamMcp.new(@server).list_tools.map { _1["name"] }
  end

  test "parses text/event-stream responses" do
    stub_request(:post, URL).to_return do |req|
      msg = ::JSON.parse(req.body)
      case msg["method"]
      when "initialize" then { body: rpc_json(msg["id"], result: {}), headers: JSON_CT }
      when "notifications/initialized" then { status: 202 }
      else
        { headers: { "Content-Type" => "text/event-stream" },
          body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: #{rpc_json(msg['id'], result: { content: [ { type: 'text', text: 'sse' } ] })}\n\n" }
      end
    end
    result = UpstreamMcp.new(@server).call_tool("echo", { "text" => "x" })
    assert_equal "sse", result["content"][0]["text"]
  end

  test "re-initializes when the session expires (404)" do
    inits = 0
    stub_request(:delete, URL).to_return(status: 204)
    stub_request(:post, URL).to_return do |req|
      msg = ::JSON.parse(req.body)
      case msg["method"]
      when "initialize"
        { body: rpc_json(msg["id"], result: {}), headers: JSON_CT.merge("Mcp-Session-Id" => "s#{inits += 1}") }
      when "notifications/initialized" then { status: 202 }
      when "tools/call"
        if req.headers["Mcp-Session-Id"] == "s1"
          { status: 404, body: "gone" }
        else
          { body: rpc_json(msg["id"], result: { content: [ { type: "text", text: "ok" } ] }), headers: JSON_CT }
        end
      end
    end
    result = UpstreamMcp.new(@server).call_tool("echo", {})
    assert_equal "ok", result["content"][0]["text"]
    assert_equal 2, inits
  end

  test "closes the upstream session with DELETE after an operation" do
    stub_upstream(URL)
    UpstreamMcp.new(@server).list_tools
    assert_requested(:delete, URL, times: 1) { |r| r.headers["Mcp-Session-Id"] == "sess-1" }
  end

  test "raises AuthError on 401" do
    stub_request(:post, URL).to_return(status: 401)
    assert_raises(UpstreamMcp::AuthError) { UpstreamMcp.new(@server).list_tools }
  end

  test "raises TimeoutError" do
    stub_request(:post, URL).to_timeout
    assert_raises(UpstreamMcp::TimeoutError) { UpstreamMcp.new(@server).list_tools }
  end

  test "raises RpcError for JSON-RPC errors" do
    stub_request(:post, URL).to_return do |req|
      msg = ::JSON.parse(req.body)
      case msg["method"]
      when "initialize" then { body: rpc_json(msg["id"], result: {}), headers: JSON_CT }
      when "tools/call" then { body: rpc_json(msg["id"], error: { code: -32602, message: "bad args" }), headers: JSON_CT }
      else { status: 202 }
      end
    end
    err = assert_raises(UpstreamMcp::RpcError) { UpstreamMcp.new(@server).call_tool("echo", {}) }
    assert_equal(-32602, err.code)
  end

  test "raises ProtocolError on invalid JSON" do
    stub_request(:post, URL).to_return(body: "<html>", headers: JSON_CT)
    assert_raises(UpstreamMcp::ProtocolError) { UpstreamMcp.new(@server).list_tools }
  end

  test "blocks hosts resolving to private or link-local addresses" do
    %w[127.0.0.1 10.0.0.5 192.168.1.1 172.16.0.1 169.254.169.254 ::1 fd00::1 ::ffff:127.0.0.1].each do |ip|
      UpstreamMcp.resolver = ->(_) { [ ip ] }
      assert_raises(UpstreamMcp::BlockedAddressError, "expected #{ip} blocked") { UpstreamMcp.new(@server).list_tools }
    end
  end

  test "blocks if any resolved address is private" do
    UpstreamMcp.resolver = ->(_) { [ "93.184.216.34", "10.0.0.1" ] }
    assert_raises(UpstreamMcp::BlockedAddressError) { UpstreamMcp.new(@server).list_tools }
  end

  test "ALLOW_PRIVATE_UPSTREAMS permits private addresses" do
    Rails.configuration.x.gateway.allow_private_upstreams = true
    UpstreamMcp.resolver = ->(_) { [ "127.0.0.1" ] }
    stub_upstream(URL)
    assert_equal 2, UpstreamMcp.new(@server).list_tools.size
  end
end
