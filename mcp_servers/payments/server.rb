require_relative "../lib/server_app"
require_relative "store"

class InitiateRefund < MCP::Tool
  tool_name "initiate_refund"
  description "Initiate a full refund for the captured payment of an order. Fails if the order has no payment, " \
              "the payment is not captured, or it was already refunded."
  input_schema(
    properties: {
      order_id: { type: "string", description: "Order id, e.g. ORD-1001" },
      reason: { type: "string", description: "Optional reason for the refund" }
    },
    required: ["order_id"]
  )
  annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: false, open_world_hint: false)

  def self.call(order_id:, reason: nil, server_context: nil)
    ServerApp.json(PaymentStore.initiate_refund(order_id, reason: reason))
  rescue PaymentStore::NotFound, PaymentStore::NotRefundable => e
    ServerApp.text(e.message, error: true)
  end
end

APP = ServerApp.build(name: "payments", tools: [InitiateRefund],
                      instructions: "E-commerce payments service: initiate refunds for orders.")

ServerApp.run(APP, default_port: 9302) if $PROGRAM_NAME == __FILE__
