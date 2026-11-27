# GET /mcp: server-to-client SSE stream. Sends notifications/tools/list_changed
# whenever the aggregated tool set changes, so clients re-fetch tools/list immediately.
class McpStreamController < ActionController::API
  include ActionController::Live
  include GatewayAuthentication
  before_action :authenticate_gateway_token!

  KEEPALIVE_SECONDS = 15
  NOTIFICATION = { jsonrpc: "2.0", method: "notifications/tools/list_changed" }.freeze

  def show
    unless request.headers["Accept"].to_s.include?("text/event-stream")
      response.set_header("Allow", "POST")
      return render json: GatewayRpc.error_body(nil, GatewayRpc::INVALID_REQUEST, "Use POST, or GET with Accept: text/event-stream"),
                    status: :method_not_allowed
    end

    queue = begin
      ToolsChangedBroadcaster.subscribe
    rescue ToolsChangedBroadcaster::TooManyStreams
      return render json: GatewayRpc.error_body(nil, -32029, "Too many open streams"), status: :service_unavailable
    end

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
    ActiveRecord::Base.connection_pool.release_connection # don't hold a DB connection while idle

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Rails.configuration.x.gateway.stream_max_seconds
    opened = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    reason = "max lifetime reached"
    Rails.logger.info("[mcp-gateway] SSE stream opened caller=#{caller_label} open_streams=#{ToolsChangedBroadcaster.subscriber_count}")
    response.stream.write(": connected\n\n")
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0

      event = queue.pop(timeout: [KEEPALIVE_SECONDS, remaining].min)
      if event
        queue.clear # coalesce bursts into one notification
        response.stream.write("event: message\ndata: #{JSON.generate(NOTIFICATION)}\n\n")
        Rails.logger.info("[mcp-gateway] sent notifications/tools/list_changed to caller=#{caller_label}")
      else
        response.stream.write(": keepalive\n\n")
      end
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    reason = "client disconnected"
  ensure
    if queue
      secs = opened ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - opened).round : 0
      Rails.logger.info("[mcp-gateway] SSE stream closed after #{secs}s (#{reason || 'error'}) caller=#{caller_label}")
    end
    ToolsChangedBroadcaster.unsubscribe(queue) if queue
    response.stream.close
  end

  private

  def caller_label
    @principal ? "sub:#{@principal.sub}" : @gateway_token&.name.inspect
  end
end
