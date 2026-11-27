# Handles JSON-RPC 2.0 requests for the aggregated /mcp endpoint.
class GatewayRpc
  PROTOCOL_VERSION = "2025-06-18"
  PARSE_ERROR = -32700
  INVALID_REQUEST = -32600
  METHOD_NOT_FOUND = -32601
  INVALID_PARAMS = -32602
  INTERNAL_ERROR = -32603

  Result = Struct.new(:status, :body)

  def self.error_body(id, code, message)
    { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  end

  WHOAMI_TOOL = {
    "name" => "whoami",
    "description" => "Returns the authenticated caller's subject (sub) and granted scopes.",
    "inputSchema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
  }.freeze

  def initialize(gateway_token: nil, principal: nil, subject_token: nil)
    @token = gateway_token
    @principal = principal # Oidc::Principal when authenticated via Keycloak
    @subject_token = subject_token # TokenExchange::Secret; only ever sent to the token exchange server
  end

  # raw: request body string. Returns Result(status, body-hash-or-nil).
  def handle(raw)
    msg = begin
      JSON.parse(raw)
    rescue JSON::ParserError, TypeError
      return Result.new(200, self.class.error_body(nil, PARSE_ERROR, "Parse error"))
    end
    return Result.new(200, self.class.error_body(nil, INVALID_REQUEST, "Invalid Request")) unless msg.is_a?(Hash)

    # Client responses and notifications carry no id / no method: acknowledge.
    return Result.new(202, nil) unless msg.key?("id") && msg["method"]

    id = msg["id"]
    unless msg["method"].is_a?(String) && (id.nil? || id.is_a?(String) || id.is_a?(Numeric))
      return Result.new(200, self.class.error_body(nil, INVALID_REQUEST, "Invalid Request"))
    end

    params = msg["params"]
    params = {} if params.nil?
    return Result.new(200, self.class.error_body(id, INVALID_PARAMS, "params must be an object")) unless params.is_a?(Hash)

    result = dispatch(msg["method"], params)
    if result.is_a?(Array) # [code, message]
      Result.new(200, self.class.error_body(id, *result))
    else
      Result.new(200, { jsonrpc: "2.0", id: id, result: result })
    end
  rescue => e
    Rails.logger.error("[mcp-gateway] internal error: #{e.class}: #{e.message}")
    Result.new(200, self.class.error_body(msg.is_a?(Hash) ? msg["id"] : nil, INTERNAL_ERROR, "Internal error"))
  end

  private

  def dispatch(method, params)
    case method
    when "initialize" then initialize_result(params)
    when "ping" then {}
    when "tools/list" then { tools: (@principal ? [ WHOAMI_TOOL ] : []) + ToolCatalog.tools }
    when "tools/call" then call_tool(params)
    else [ METHOD_NOT_FOUND, "Method not found: #{method}" ]
    end
  end

  def initialize_result(params)
    requested = params["protocolVersion"]
    {
      protocolVersion: (requested == PROTOCOL_VERSION ? requested : PROTOCOL_VERSION),
      capabilities: { tools: { listChanged: true } },
      serverInfo: { name: "mcp-gateway", version: "1.0.0" }
    }
  end

  def call_tool(params)
    name = params["name"]
    return [ INVALID_PARAMS, "Missing tool name" ] unless name.is_a?(String) && name.present?
    arguments = params.fetch("arguments", {})
    arguments = {} if arguments.nil?
    return [ INVALID_PARAMS, "arguments must be an object" ] unless arguments.is_a?(Hash)

    return whoami if @principal && name == WHOAMI_TOOL["name"]

    server, tool = ToolCatalog.resolve(name)
    return [ INVALID_PARAMS, "Unknown tool: #{name}" ] unless server
    unless server.tool_enabled?(tool["name"])
      return [ INVALID_PARAMS, "Tool is disabled: #{name}" ]
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      bearer = nil
      if server.token_exchange?
        denial = exchange_denial(server, tool["name"])
        if denial
          log_call(server, tool["name"], "error", started, denial)
          return error_result(denial)
        end
        bearer = TokenExchange.exchange_for_tool(server, @subject_token, tool["name"])
      end
      result = UpstreamMcp.new(server, bearer_token: bearer).call_tool(tool["name"], arguments)
      log_call(server, tool["name"], result["isError"] ? "error" : "ok", started, result["isError"] ? "Upstream tool reported isError" : nil)
      limit_size(result)
    rescue UpstreamMcp::RpcError => e
      log_call(server, tool["name"], "error", started, "RPC #{e.code}: #{e.message}")
      error_result("Upstream error#{" (#{e.code})" if e.code}: #{e.message}")
    rescue UpstreamMcp::Error => e
      log_call(server, tool["name"], "error", started, "#{e.class.name.demodulize}: #{e.message}")
      error_result("Upstream call failed: #{e.message}")
    rescue TokenExchange::Error => e
      log_call(server, tool["name"], "error", started, "TokenExchange #{e.class.name.demodulize}: #{e.message}")
      error_result("Token exchange for #{server.name} failed; the tool was not called.")
    end
  end

  # Fail closed: token-exchange upstreams need a validated Keycloak caller holding the tool scope.
  # (The controller already returns 403 for a missing scope; this is the second line of defense.)
  def exchange_denial(server, tool_name)
    return "#{server.name} requires a Keycloak sign-in (OIDC mode)" unless @principal && @subject_token
    required = server.required_scope_for(tool_name)
    return "No scope configured for #{tool_name}" unless required
    return "Missing scope #{required}" unless @principal.scopes.include?(required)
    nil
  end

  def whoami
    payload = { sub: @principal.sub, scopes: @principal.scopes }
    { content: [ { type: "text", text: JSON.generate(payload) } ], structuredContent: payload, isError: false }
  end

  def error_result(text)
    { content: [ { type: "text", text: text } ], isError: true }
  end

  def log_call(server, tool_name, status, started, error)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    CallLog.create!(mcp_server: server, tool_name: tool_name, gateway_token: @token,
                    status: status, duration_ms: ms, error: error&.truncate(1000))
  rescue => e
    Rails.logger.error("[mcp-gateway] call log failed: #{e.message}")
  end

  # Returns the upstream result as is, unless it exceeds the size cap.
  def limit_size(result)
    max = Rails.configuration.x.gateway.max_result_bytes
    return result if JSON.generate(result).bytesize <= max

    text = Array(result["content"]).filter_map { |c| c["text"] if c.is_a?(Hash) && c["type"] == "text" }.join("\n")
    text = JSON.generate(result["content"]) if text.empty?
    truncated = text.byteslice(0, max).scrub("")
    { "content" => [ { "type" => "text", "text" => "#{truncated}\n\n[truncated: result exceeded #{max} bytes]" } ],
      "isError" => result["isError"] || false }
  end
end
