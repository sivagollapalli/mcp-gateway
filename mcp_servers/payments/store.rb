require "securerandom"
require "time"

# In-memory payment/refund store seeded with sample data (resets on restart).
module PaymentStore
  @mutex = Mutex.new
  @payments = {
    "ORD-1001" => { order_id: "ORD-1001", payment_id: "PAY-5001", amount: 129.99, currency: "USD", status: "captured", refunds: [] },
    "ORD-1002" => { order_id: "ORD-1002", payment_id: "PAY-5002", amount: 54.5, currency: "USD", status: "captured", refunds: [] },
    "ORD-1003" => { order_id: "ORD-1003", payment_id: "PAY-5003", amount: 19.0, currency: "USD", status: "authorized", refunds: [] }
  }

  class NotFound < StandardError; end
  class NotRefundable < StandardError; end

  # Full refund of the captured amount for the order.
  def self.initiate_refund(order_id, reason: nil)
    @mutex.synchronize do
      payment = @payments[order_id.to_s] or raise NotFound, "No payment found for order #{order_id}"
      raise NotRefundable, "Order #{order_id} was already refunded (#{payment[:refunds].last[:refund_id]})" if payment[:status] == "refunded"
      raise NotRefundable, "Payment for order #{order_id} is '#{payment[:status]}'; only captured payments can be refunded" unless payment[:status] == "captured"

      refund = { refund_id: "RF-#{SecureRandom.hex(4).upcase}", order_id: payment[:order_id], payment_id: payment[:payment_id],
                 amount: payment[:amount], currency: payment[:currency], status: "initiated",
                 reason: reason, created_at: Time.now.utc.iso8601 }
      payment[:refunds] << refund
      payment[:status] = "refunded"
      refund
    end
  end
end
