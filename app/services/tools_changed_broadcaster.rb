# In-process fan-out of "tool set changed" events to open GET /mcp SSE streams.
# Works within one server process (see README for multi-process notes).
module ToolsChangedBroadcaster
  MAX_SUBSCRIBERS = 5
  @mutex = Mutex.new
  @subscribers = []

  class TooManyStreams < StandardError; end

  module_function

  def subscribe
    queue = Queue.new
    @mutex.synchronize do
      raise TooManyStreams if @subscribers.size >= MAX_SUBSCRIBERS
      @subscribers << queue
    end
    queue
  end

  def unsubscribe(queue)
    @mutex.synchronize { @subscribers.delete(queue) }
  end

  def broadcast
    count = @mutex.synchronize { @subscribers.each { |q| q << :tools_changed }.size }
    Rails.logger.info("[mcp-gateway] tools changed: notifying #{count} open stream(s)")
    count
  end

  def subscriber_count = @mutex.synchronize { @subscribers.size }
end
