class Rack::Attack
  Rack::Attack.cache.store = Rails.cache
  Rack::Attack.enabled = !Rails.env.test?

  # Throttle /mcp per gateway token (or IP when none is supplied).
  throttle("mcp/token", limit: ->(_req) { Rails.configuration.x.gateway.rate_limit }, period: 1.minute) do |req|
    next unless req.path == "/mcp"
    auth = req.get_header("HTTP_AUTHORIZATION").to_s
    auth.present? ? "t:#{Digest::SHA256.hexdigest(auth)}" : "ip:#{req.ip}"
  end

  # Always throttle by IP too, so unauthenticated floods are bounded.
  throttle("mcp/ip", limit: ->(_req) { Rails.configuration.x.gateway.rate_limit * 3 }, period: 1.minute) do |req|
    req.ip if req.path == "/mcp"
  end

  throttle("login/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.path == "/session" && req.post?
  end

  self.throttled_responder = lambda do |req|
    if req.path == "/mcp"
      body = { jsonrpc: "2.0", id: nil, error: { code: -32029, message: "Rate limit exceeded" } }.to_json
      [ 429, { "Content-Type" => "application/json", "Retry-After" => "60" }, [ body ] ]
    else
      [ 429, { "Content-Type" => "text/plain", "Retry-After" => "60" }, [ "Too many requests\n" ] ]
    end
  end
end
