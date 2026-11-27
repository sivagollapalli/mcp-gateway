require "net/http"
require "json"
require "resolv"
require "ipaddr"

# Minimal MCP (Streamable HTTP) client over plain Net::HTTP + JSON-RPC 2.0.
class UpstreamMcp
  PROTOCOL_VERSION = "2025-06-18"
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 30
  MAX_PAGES = 50

  class Error < StandardError; end
  class BlockedAddressError < Error; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
  class AuthError < Error; end
  class SessionExpired < Error; end
  class ProtocolError < Error; end
  class HttpError < Error; end
  class RpcError < Error
    attr_reader :code, :data
    def initialize(message, code: nil, data: nil)
      super(message)
      @code = code
      @data = data
    end
  end

  # Returns the list of IP address strings a host resolves to. Overridable in tests.
  class_attribute :resolver, default: ->(host) { Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq }

  attr_reader :session_id

  # bearer_token: the exchanged, audience-bound token for token_exchange servers. Headers are
  # always built from scratch here; nothing from the inbound client request is copied.
  def initialize(server, bearer_token: nil)
    @server = server
    @bearer_token = bearer_token
    @uri = URI.parse(server.url)
    @session_id = nil
    @initialized = false
    @next_id = 0
  end

  def inspect = "#<UpstreamMcp server=#{@server.name}>" # never expose credentials

  def initialize!
    result = request("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "mcp-gateway", version: "1.0" }
    }, allow_reinit: false)
    @initialized = true
    notify("notifications/initialized")
    result
  end

  # Ends the upstream session (best effort; servers may answer 405 or not track sessions).
  def close
    return unless @session_id
    address = validate_destination!
    http = build_http(address)
    req = Net::HTTP::Delete.new(@uri.request_uri)
    headers.each { |k, v| req[k] = v unless k == "Content-Type" }
    http.start { |conn| conn.request(req) }
  rescue Error, StandardError => e
    Rails.logger.debug { "[upstream-mcp] session close failed: #{e.class}: #{e.message}" }
  ensure
    @session_id = nil
    @initialized = false
  end

  def list_tools
    ensure_initialized
    tools = []
    cursor = nil
    MAX_PAGES.times do
      result = request("tools/list", cursor ? { cursor: cursor } : {})
      tools.concat(Array(result["tools"]))
      cursor = result["nextCursor"]
      return tools if cursor.blank?
    end
    raise ProtocolError, "tools/list pagination exceeded #{MAX_PAGES} pages"
  ensure
    close
  end

  def call_tool(name, arguments = {})
    ensure_initialized
    request("tools/call", { name: name, arguments: arguments || {} })
  ensure
    close
  end

  private

  def ensure_initialized
    initialize! unless @initialized
  end

  def next_id = (@next_id += 1)

  def request(method, params, allow_reinit: true)
    id = next_id
    body = { jsonrpc: "2.0", id: id, method: method, params: params }
    message = begin
      post(body, expect_id: id)
    rescue SessionExpired
      raise unless allow_reinit && @session_id
      @session_id = nil
      @initialized = false
      initialize!
      post(body, expect_id: id)
    end
    raise ProtocolError, "No response from upstream for #{method}" if message.nil?
    if message["error"]
      err = message["error"]
      raise RpcError.new(err["message"].to_s, code: err["code"], data: err["data"])
    end
    message["result"] || {}
  end

  def notify(method)
    post({ jsonrpc: "2.0", method: method }, expect_id: nil)
  rescue Error => e
    Rails.logger.warn("[upstream-mcp] notification #{method} failed: #{e.message}")
  end

  def post(body, expect_id:)
    address = validate_destination!
    http = build_http(address)

    req = Net::HTTP::Post.new(@uri.request_uri)
    headers.each { |k, v| req[k] = v }
    req.body = JSON.generate(body)

    message = nil
    http.start do |conn|
      conn.request(req) do |res|
        message = handle_response(res, expect_id)
      end
    end
    message
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise TimeoutError, "Upstream timed out (#{e.class.name.demodulize})"
  rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, IOError => e
    raise ConnectionError, "Connection failed: #{e.message}"
  end

  def build_http(address)
    http = Net::HTTP.new(@uri.host, @uri.port)
    http.use_ssl = @uri.scheme == "https"
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http.ipaddr = address if address # connect to the vetted IP (prevents DNS rebinding)
    http
  end

  def headers
    h = {
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
    h["Mcp-Session-Id"] = @session_id if @session_id
    h["MCP-Protocol-Version"] = PROTOCOL_VERSION if @initialized
    case @server.auth_type
    when "bearer" then h["Authorization"] = "Bearer #{@server.auth_token}"
    when "token_exchange"
      raise AuthError, "No exchanged token for #{@server.name}; refusing to call it unauthenticated" if @bearer_token.blank?
      h["Authorization"] = "Bearer #{@bearer_token}"
    when "header"
      # auth_token holds a full "Header-Name: value" pair
      name, value = @server.auth_token.to_s.split(":", 2)
      h[name.strip] = value.to_s.strip if name.present? && value.present?
    end
    h
  end

  def handle_response(res, expect_id)
    code = res.code.to_i
    case code
    when 200..299
      if (sid = res["Mcp-Session-Id"]).present?
        @session_id = sid
      end
      return nil if code == 202 || expect_id.nil?
      parse_body(res, expect_id)
    when 401, 403 then raise AuthError, "Upstream rejected credentials (HTTP #{code})"
    when 404
      raise SessionExpired, "Upstream session expired" if @session_id
      raise HttpError, "Upstream returned HTTP 404"
    when 300..399 then raise HttpError, "Upstream redirected (HTTP #{code}); redirects are not followed"
    else
      snippet = res.body.to_s[0, 200].gsub(/\s+/, " ")
      raise HttpError, "Upstream returned HTTP #{code}#{": #{snippet}" if snippet.present?}"
    end
  end

  def parse_body(res, expect_id)
    type = res["Content-Type"].to_s.downcase
    if type.include?("text/event-stream")
      parse_sse(res, expect_id)
    else
      raw = res.read_body.to_s
      data = JSON.parse(raw)
      pick(data, expect_id) || raise(ProtocolError, "Upstream response did not contain a reply for id #{expect_id}")
    end
  rescue JSON::ParserError
    raise ProtocolError, "Upstream returned invalid JSON"
  end

  # Reads the SSE stream incrementally and stops at the reply matching expect_id.
  def parse_sse(res, expect_id)
    buffer = +""
    found = nil
    res.read_body do |chunk|
      buffer << chunk
      while (idx = buffer.index(/\r?\n\r?\n/))
        event = buffer.slice!(0, idx + $~[0].length)
        data = event.each_line.filter_map { |l| l.sub(/\r?\n\z/, "")[/\Adata:\s?(.*)\z/, 1] }.join("\n")
        next if data.empty?
        parsed = (JSON.parse(data) rescue nil)
        found = pick(parsed, expect_id) if parsed
        break if found
      end
      break if found
    end
    found || raise(ProtocolError, "SSE stream ended without a reply for id #{expect_id}")
  end

  def pick(data, expect_id)
    candidates = data.is_a?(Array) ? data : [ data ]
    candidates.find { |m| m.is_a?(Hash) && m["id"] == expect_id && (m.key?("result") || m.key?("error")) }
  end

  # SSRF guard. Returns the IP to connect to (nil when private upstreams are allowed).
  def validate_destination!
    unless %w[http https].include?(@uri.scheme) && @uri.host.present?
      raise BlockedAddressError, "Invalid upstream URL"
    end
    return nil if Rails.configuration.x.gateway.allow_private_upstreams

    host = @uri.host.delete_prefix("[").delete_suffix("]")
    addresses = begin
      self.class.resolver.call(host)
    rescue SocketError, Resolv::ResolvError => e
      raise ConnectionError, "Could not resolve #{host}: #{e.message}"
    end
    raise ConnectionError, "Could not resolve #{host}" if addresses.empty?

    addresses.each do |a|
      raise BlockedAddressError, "Upstream #{host} resolves to a private/link-local address (#{a})" if self.class.blocked_ip?(a)
    end
    addresses.first
  end

  def self.blocked_ip?(address)
    ip = IPAddr.new(address.to_s.split("%").first)
    ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
    ip.private? || ip.loopback? || ip.link_local? ||
      IPAddr.new("0.0.0.0/8").include?(ip) || IPAddr.new("100.64.0.0/10").include?(ip) ||
      IPAddr.new("::").==(ip) || IPAddr.new("224.0.0.0/4").include?(ip) || IPAddr.new("ff00::/8").include?(ip)
  rescue IPAddr::Error
    true
  end
end
