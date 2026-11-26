require_relative "../lib/server_app"
require_relative "store"

class GetOrder < MCP::Tool
  tool_name "get_order"
  description "Get an order (customer, items, total and current status) by its order id, e.g. ORD-1001."
  input_schema(
    properties: { order_id: { type: "string", description: "Order id, e.g. ORD-1001" } },
    required: ["order_id"]
  )
  annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(order_id:, server_context: nil)
    ServerApp.json(OrderStore.find(order_id))
  rescue OrderStore::NotFound => e
    ServerApp.text(e.message, error: true)
  end
end

class CreateOrder < MCP::Tool
  tool_name "create_order"
  description "Create a new order for a customer with one or more line items. The order starts in 'pending' status; " \
              "the total is calculated from the items. Returns the new order including its generated order id."
  input_schema(
    properties: {
      customer: { type: "string", description: "Customer name" },
      items: {
        type: "array",
        minItems: 1,
        description: "Line items",
        items: {
          type: "object",
          properties: {
            sku: { type: "string", description: "Product SKU" },
            name: { type: "string", description: "Product name (defaults to the SKU)" },
            qty: { type: "integer", minimum: 1, description: "Quantity" },
            price: { type: "number", minimum: 0, description: "Unit price" }
          },
          required: %w[sku qty price]
        }
      },
      currency: { type: "string", description: "ISO currency code, default USD" }
    },
    required: %w[customer items]
  )
  annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

  def self.call(customer:, items:, currency: "USD", server_context: nil)
    ServerApp.json(OrderStore.create(customer: customer, items: items, currency: currency))
  rescue OrderStore::InvalidOrder => e
    ServerApp.text(e.message, error: true)
  end
end

class UpdateOrder < MCP::Tool
  tool_name "update_order"
  description "Update the status of an order. Allowed statuses: #{OrderStore::STATUSES.join(', ')}. " \
              "Transitions are validated (e.g. a delivered order cannot be changed)."
  input_schema(
    properties: {
      order_id: { type: "string", description: "Order id, e.g. ORD-1001" },
      status: { type: "string", enum: OrderStore::STATUSES, description: "New status" }
    },
    required: %w[order_id status]
  )
  annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(order_id:, status:, server_context: nil)
    ServerApp.json(OrderStore.update_status(order_id, status))
  rescue OrderStore::NotFound, OrderStore::InvalidTransition => e
    ServerApp.text(e.message, error: true)
  end
end

APP = ServerApp.build(name: "orders", tools: [GetOrder, CreateOrder, UpdateOrder],
                      instructions: "E-commerce orders service: create, look up and update orders.")

ServerApp.run(APP, default_port: 9301) if $PROGRAM_NAME == __FILE__
