require "time"

# In-memory order store seeded with sample data (resets when the server restarts).
module OrderStore
  STATUSES = %w[pending paid processing shipped delivered cancelled].freeze

  # Allowed status transitions.
  TRANSITIONS = {
    "pending" => %w[paid cancelled],
    "paid" => %w[processing cancelled],
    "processing" => %w[shipped cancelled],
    "shipped" => %w[delivered],
    "delivered" => [],
    "cancelled" => []
  }.freeze

  @mutex = Mutex.new
  @orders = {
    "ORD-1001" => { order_id: "ORD-1001", customer: "Alice Johnson", status: "paid", total: 129.99, currency: "USD",
                    items: [{ sku: "SKU-HEADPHONES", name: "Wireless Headphones", qty: 1, price: 129.99 }] },
    "ORD-1002" => { order_id: "ORD-1002", customer: "Bob Smith", status: "shipped", total: 54.5, currency: "USD",
                    items: [{ sku: "SKU-MUG", name: "Ceramic Mug", qty: 2, price: 12.25 }, { sku: "SKU-BEANS", name: "Coffee Beans 1kg", qty: 1, price: 30.0 }] },
    "ORD-1003" => { order_id: "ORD-1003", customer: "Carol Diaz", status: "pending", total: 19.0, currency: "USD",
                    items: [{ sku: "SKU-NOTEBOOK", name: "Notebook", qty: 1, price: 19.0 }] }
  }.each_value { |o| o[:updated_at] = Time.now.utc.iso8601 }

  class NotFound < StandardError; end
  class InvalidTransition < StandardError; end
  class InvalidOrder < StandardError; end

  # items: [{ "sku", "qty", "price", "name"? }]. New orders start as "pending".
  def self.create(customer:, items:, currency: "USD")
    raise InvalidOrder, "customer is required" if customer.to_s.strip.empty?
    raise InvalidOrder, "items must be a non-empty list" unless items.is_a?(Array) && !items.empty?

    normalized = items.each_with_index.map do |raw, i|
      item = raw.to_h.transform_keys(&:to_s)
      sku = item["sku"].to_s.strip
      qty = item["qty"]
      price = item["price"]
      raise InvalidOrder, "items[#{i}].sku is required" if sku.empty?
      raise InvalidOrder, "items[#{i}].qty must be a positive integer" unless qty.is_a?(Integer) && qty.positive?
      raise InvalidOrder, "items[#{i}].price must be a number >= 0" unless price.is_a?(Numeric) && price >= 0

      { sku: sku, name: item["name"].to_s.strip.then { |n| n.empty? ? sku : n }, qty: qty, price: price.to_f }
    end

    @mutex.synchronize do
      next_number = @orders.keys.map { |k| k[/\d+\z/].to_i }.max.to_i + 1
      order_id = "ORD-#{next_number}"
      order = {
        order_id: order_id, customer: customer.to_s.strip, status: "pending",
        total: normalized.sum { |i| i[:qty] * i[:price] }.round(2), currency: currency.to_s.upcase,
        items: normalized, updated_at: Time.now.utc.iso8601
      }
      @orders[order_id] = order
      order.dup
    end
  end

  def self.find(order_id)
    @mutex.synchronize { @orders[order_id.to_s]&.dup } or raise NotFound, "Order #{order_id} not found"
  end

  def self.update_status(order_id, status)
    status = status.to_s.downcase
    raise InvalidTransition, "Invalid status '#{status}'. Allowed: #{STATUSES.join(', ')}" unless STATUSES.include?(status)

    @mutex.synchronize do
      order = @orders[order_id.to_s] or raise NotFound, "Order #{order_id} not found"
      current = order[:status]
      unless current == status || TRANSITIONS[current].include?(status)
        raise InvalidTransition, "Cannot change order #{order_id} from '#{current}' to '#{status}'. " \
                                 "Allowed from '#{current}': #{TRANSITIONS[current].join(', ').then { |s| s.empty? ? 'none' : s }}"
      end
      order[:previous_status] = current
      order[:status] = status
      order[:updated_at] = Time.now.utc.iso8601
      order.dup
    end
  end
end
