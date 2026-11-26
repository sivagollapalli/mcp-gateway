require "test_helper"

class McpStreamTest < ActionDispatch::IntegrationTest
  setup do
    _, @token = GatewayToken.generate!(name: "t")
    Rails.configuration.x.gateway.stream_max_seconds = 1
  end

  teardown { Rails.configuration.x.gateway.stream_max_seconds = 300 }

  test "requires a bearer token" do
    get "/mcp", headers: { "Accept" => "text/event-stream" }
    assert_response :unauthorized
  end

  test "GET without an SSE Accept header returns 405" do
    get "/mcp", headers: { "Authorization" => "Bearer #{@token}" }
    assert_response :method_not_allowed
  end

  test "streams tools/list_changed when the tool set changes" do
    Thread.new do
      sleep 0.3
      ToolCatalog.bump!
    end
    get "/mcp", headers: { "Authorization" => "Bearer #{@token}", "Accept" => "text/event-stream" }
    assert_response :success
    assert_equal "text/event-stream", response.media_type
    assert_includes response.body, "notifications/tools/list_changed"
    assert_equal 0, ToolsChangedBroadcaster.subscriber_count
  end

  test "bump! broadcasts to subscribers" do
    q = ToolsChangedBroadcaster.subscribe
    ToolCatalog.bump!
    assert_equal :tools_changed, q.pop(timeout: 1)
  ensure
    ToolsChangedBroadcaster.unsubscribe(q)
  end

  test "stream count is capped" do
    qs = Array.new(ToolsChangedBroadcaster::MAX_SUBSCRIBERS) { ToolsChangedBroadcaster.subscribe }
    get "/mcp", headers: { "Authorization" => "Bearer #{@token}", "Accept" => "text/event-stream" }
    assert_response :service_unavailable
  ensure
    qs&.each { |q| ToolsChangedBroadcaster.unsubscribe(q) }
  end
end
