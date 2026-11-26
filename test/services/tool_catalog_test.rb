require "test_helper"

class ToolCatalogTest < ActiveSupport::TestCase
  test "prefixes tool names with the server name" do
    assert_equal "alpha__echo", ToolCatalog.encode_name("alpha", "echo")
  end

  test "sanitizes illegal characters" do
    name = ToolCatalog.encode_name("alpha", "do.thing/now")
    assert_match(/\A[a-zA-Z0-9_-]+\z/, name)
    assert name.start_with?("alpha__do_thing_now")
  end

  test "keeps names within 64 chars and unique after truncation" do
    n1 = ToolCatalog.encode_name("alpha", "a" * 100 + "1")
    n2 = ToolCatalog.encode_name("alpha", "a" * 100 + "2")
    assert_operator n1.length, :<=, 64
    assert_not_equal n1, n2
    assert_match(/\A[a-zA-Z0-9_-]+\z/, n1)
  end

  test "splits on the first double underscore only" do
    assert_equal [ "alpha", "my__tool" ], ToolCatalog.split_name("alpha__my__tool")
    assert_nil ToolCatalog.split_name("nodelimiter")
    assert_nil ToolCatalog.split_name("alpha__")
  end

  test "server names cannot contain double underscores" do
    server = McpServer.new(name: "bad__name", url: "https://x.example.com")
    assert_not server.valid?
    assert_includes server.errors[:name].join, "consecutive"
  end

  test "tools lists enabled servers only, prefixed" do
    create_server_with_tools(name: "alpha")
    create_server_with_tools(name: "beta", enabled: false)
    assert_equal %w[alpha__add alpha__echo], ToolCatalog.tools.map { |t| t["name"] }.sort
  end

  test "tool policy hides disabled tools" do
    server = create_server_with_tools
    assert_includes ToolCatalog.tools.map { |t| t["name"] }, "alpha__echo"
    server.tool_policies.create!(tool_name: "echo", enabled: false)
    names = ToolCatalog.tools.map { |t| t["name"] }
    assert_not_includes names, "alpha__echo"
    assert_includes names, "alpha__add"
  end

  test "failing upstream is skipped and does not break the list" do
    create_server_with_tools(name: "alpha")
    bad = create_server(name: "broken", url: "https://broken.example.com/mcp")
    stub_request(:post, "https://broken.example.com/mcp").to_timeout
    assert_equal %w[alpha__add alpha__echo], ToolCatalog.tools.map { |t| t["name"] }.sort
    assert_equal "error", bad.reload.last_status
  end

  test "stale servers are refreshed on list" do
    server = create_server
    stub_upstream(server.url)
    assert_equal %w[alpha__add alpha__echo], ToolCatalog.tools.map { |t| t["name"] }.sort
    assert_equal 2, server.reload.tools_count
  end

  test "descriptions are truncated to 2000 chars" do
    tool = ToolCatalog.sanitize_tool("name" => "x", "description" => "a" * 5000)
    assert_operator tool["description"].length, :<=, 2000
  end

  test "resolve maps a gateway name back to the upstream tool" do
    server = create_server_with_tools
    found_server, tool = ToolCatalog.resolve("alpha__echo")
    assert_equal server, found_server
    assert_equal "echo", tool["name"]
    assert_nil ToolCatalog.resolve("alpha__missing")
    assert_nil ToolCatalog.resolve("nope__echo")
  end
end
