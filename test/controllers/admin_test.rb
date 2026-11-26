require "test_helper"

class AdminTest < ActionDispatch::IntegrationTest
  test "admin pages require login" do
    [ root_path, mcp_servers_path, gateway_tokens_path, call_logs_path, connect_path ].each do |path|
      get path
      assert_redirected_to new_session_path
    end
  end

  test "login with bad and good credentials" do
    user = User.create!(email: "admin@example.com", password: "password123")
    post session_path, params: { email: user.email, password: "nope" }
    assert_response :unprocessable_content
    sign_in(user)
    assert_redirected_to root_path
    get root_path
    assert_response :success
  end

  test "pages render" do
    sign_in
    server = create_server_with_tools
    CallLog.create!(mcp_server: server, tool_name: "echo", status: "error", error: "x")
    [ root_path, mcp_servers_path, mcp_server_path(server), new_mcp_server_path, edit_mcp_server_path(server),
     gateway_tokens_path, new_gateway_token_path, call_logs_path(status: "error", server_id: server.id), connect_path ].each do |path|
      get path
      assert_response :success, path
    end
  end

  test "create server validates and enqueues refresh" do
    sign_in
    post mcp_servers_path, params: { mcp_server: { name: "Bad Name", url: "nope", auth_type: "bearer" } }
    assert_response :unprocessable_content
    assert_difference "McpServer.count", 1 do
      assert_enqueued_with(job: RefreshToolsJob) do
        post mcp_servers_path, params: { mcp_server: { name: "good_one", url: "https://x.example.com/mcp", auth_type: "bearer", auth_token: "tok" } }
      end
    end
    server = McpServer.find_by!(name: "good_one")
    assert_equal "tok", server.auth_token
    assert_not_equal "tok", server.read_attribute_before_type_cast(:auth_token) # encrypted at rest
  end

  test "updating without a token keeps the stored secret" do
    sign_in
    server = create_server(auth_type: "bearer", auth_token: "keepme")
    patch mcp_server_path(server), params: { mcp_server: { name: "alpha", url: server.url, auth_type: "bearer", auth_token: "" } }
    assert_equal "keepme", server.reload.auth_token
  end

  test "refresh via turbo stream updates status" do
    sign_in
    server = create_server
    stub_upstream(server.url)
    post refresh_mcp_server_path(server), as: :turbo_stream
    assert_response :success
    assert_equal "ok", server.reload.last_status
    assert_equal 2, server.tools_count
  end

  test "toggle server and tool" do
    sign_in
    server = create_server_with_tools
    patch toggle_mcp_server_path(server), as: :turbo_stream
    assert_not server.reload.enabled?
    patch toggle_mcp_server_tool_policies_path(server, tool_name: "echo"), as: :turbo_stream
    assert_not server.tool_enabled?("echo")
    patch toggle_mcp_server_tool_policies_path(server, tool_name: "echo"), as: :turbo_stream
    assert server.tool_enabled?("echo")
  end

  test "token is shown once on create and can be revoked" do
    sign_in
    post gateway_tokens_path, params: { gateway_token: { name: "laptop" } }
    assert_response :success
    plaintext = response.body[/value="(mcpgw_[^"]+)"/, 1]
    assert plaintext
    get gateway_tokens_path
    assert_not_includes response.body, plaintext
    token = GatewayToken.find_by!(name: "laptop")
    patch revoke_gateway_token_path(token)
    assert token.reload.revoked?
  end

  test "call logs paginate and filter" do
    sign_in
    server = create_server
    30.times { CallLog.create!(mcp_server: server, tool_name: "t", status: "ok") }
    get call_logs_path
    assert_select "tbody tr", 25
    get call_logs_path(page: 2)
    assert_select "tbody tr", 5
    get call_logs_path(status: "error")
    assert_select "td", text: /No calls logged/
  end
end
