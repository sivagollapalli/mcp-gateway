# Sample e-commerce MCP servers

Two small MCP servers built with the official Ruby SDK (`mcp` gem), served over Streamable HTTP at `/mcp`, set up like the SDK's `examples/http_server.rb` (default stateful sessions, started with `ruby server.rb` through Rackup/Puma).

| Server | Port | Tools |
|---|---|---|
| `orders` | 9301 | `create_order(customer, items[], currency?)`, `get_order(order_id)`, `update_order(order_id, status)` |
| `payments` | 9302 | `initiate_refund(order_id, reason?)` |

```sh
cd mcp_servers
bundle install
./run all            # or: ./run orders | ./run payments
# equivalent: ruby orders/server.rb   (PORT=9301)   ruby payments/server.rb   (PORT=9302)
# MCP_STATELESS=1 switches to the SDK's stateless mode
```

Data is in memory with sample records (`ORD-1001`, `ORD-1002`, `ORD-1003`) and resets on restart.

- `create_order` takes `customer` and `items` (each `sku`, `qty` >= 1, `price` >= 0, optional `name`); it generates the next `ORD-<n>` id, starts the order as `pending` and totals it. The payments server has its own data, so a new order has no payment to refund.
- `update_order` validates transitions: pending → paid → processing → shipped → delivered; cancel is allowed before shipping.
- `initiate_refund` refunds the full captured amount once; a second call or an uncaptured payment returns `isError`.
- Set `MCP_TOKEN=secret` to require `Authorization: Bearer secret` (health check at `/up` stays open).

## Register in the gateway

Start the gateway with `ALLOW_PRIVATE_UPSTREAMS=true` (the servers are on localhost), then add:

| Name | URL |
|---|---|
| `orders` | `http://127.0.0.1:9301/mcp` |
| `payments` | `http://127.0.0.1:9302/mcp` |

Claude Code then sees `orders__get_order`, `orders__update_order` and `payments__initiate_refund`.
