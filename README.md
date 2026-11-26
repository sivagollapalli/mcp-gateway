# MCP Gateway

A Rails 8.1 app (Ruby 4.0) that lets you register upstream MCP servers in a web UI and exposes **one aggregated MCP endpoint** (Streamable HTTP, `POST /mcp`) for clients such as Claude Code. Tools are discovered dynamically and prefixed `<server_name>__<tool_name>`.

## Setup

```sh
bin/setup      # bundle, db:prepare (creates DB, runs migrations, seeds), then starts the server
bin/dev        # start the server later (http://localhost:3000)
```

`db:seed` creates the admin user and one disabled example server. Set the admin credentials first:

```sh
ADMIN_EMAIL=you@example.com ADMIN_PASSWORD='a-long-password' bin/rails db:seed
```

In development, if unset, the admin is `admin@example.com` / `changeme123`. In production both variables are required.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | dev only: `admin@example.com` / `changeme123` | Admin login seeded by `db:seed` |
| `ALLOW_PRIVATE_UPSTREAMS` | `true` in development, `false` otherwise | `true` allows upstreams on private/loopback/link-local addresses (needed for the mock server) |
| `MCP_MAX_RESULT_BYTES` | `100000` | Tool results larger than this are truncated to text |
| `MCP_RATE_LIMIT` | `120` | Requests/minute to `/mcp` per token (3x per IP) |
| `MCP_REFRESH_INTERVAL` | `300` | Seconds between background refreshes of all servers |
| `MCP_SCHEDULER` | auto | `1` forces / `0` disables the in-process refresh scheduler (auto: runs under `rails server`) |
| `AR_ENCRYPTION_PRIMARY_KEY`, `AR_ENCRYPTION_DETERMINISTIC_KEY`, `AR_ENCRYPTION_KEY_DERIVATION_SALT` | derived from `secret_key_base` in dev/test | Active Record encryption keys for upstream secrets. **Set these in production** (`bin/rails db:encryption:init`). Changing them makes stored secrets unreadable |
| `DATABASE_URL` | SQLite | Postgres-ready: add the `pg` gem and point `DATABASE_URL` at it |
| `RAILS_MASTER_KEY` / `SECRET_KEY_BASE` | | Standard Rails production secrets |

## Create a gateway token

1. Sign in, open **Tokens** → **Create token**, give it a name.
2. Copy the token from the confirmation page. **It is shown only once**; only its SHA-256 digest is stored.

## Connect Claude Code

```sh
claude mcp add --transport http my-gateway https://HOST/mcp --header "Authorization: Bearer <TOKEN>"
```

or an `.mcp.json`:

```json
{
  "mcpServers": {
    "my-gateway": {
      "type": "http",
      "url": "https://HOST/mcp",
      "headers": { "Authorization": "Bearer <TOKEN>" }
    }
  }
}
```

Then run `/mcp` inside Claude Code to verify. The **Connect** page in the UI shows these with your host filled in.

## How it works

- **Servers**: add upstream servers under **Servers**. Creating/updating one enqueues `RefreshToolsJob`; every server is also refreshed every 5 minutes by an in-process scheduler thread (`config/initializers/scheduler.rb`). **Test / Refresh** runs it immediately. Upstream secrets are encrypted (`encrypts`).
- **Tool names**: `<server>__<tool>`, characters outside `[a-zA-Z0-9_-]` become `_`, max 64 chars (long names get a short hash suffix). Server names cannot contain `__`, so the first `__` splits server from tool.
- **Policies**: disable individual tools on a server's page; they disappear from `tools/list` and are rejected in `tools/call`.
- **`tools/list`** is served from stored tool caches; servers whose data is older than 60 s are refreshed inline. The aggregated list is cached in `Rails.cache` under a version key that is bumped whenever tools, policies or servers change. Failing upstreams are skipped and logged.
- **`tools/call`** proxies to the upstream and returns its result unchanged (oversized text is truncated). Upstream failures become `isError` results. Each call writes a CallLog.
- **Security**: SSRF guard (private/link-local/loopback targets rejected; connection pinned to the vetted IP), tokens never logged (`filter_parameters`), descriptions truncated to 2000 chars, rack-attack rate limiting, no CSRF on `/mcp` only.

## Limitations

- **`GET /mcp` SSE stream**: with `Accept: text/event-stream` and a bearer token, the gateway holds a stream open and sends `notifications/tools/list_changed` whenever the tool set changes (refresh found changes, server or tool toggled, server added/removed). Claude Code then re-fetches `tools/list` on its own. Without the SSE `Accept` header, `GET /mcp` returns 405. Streams are in-process only (changes made by another process, e.g. `rails runner`, are not pushed), limited to 5 at a time, each holds a Puma thread (default 10), and are recycled every `MCP_STREAM_MAX_SECONDS` (300) so clients reconnect.
- Each tool call opens a fresh upstream session (initialize → call). Simple and stateless, but adds a round trip.
- In-process scheduler and the dev `memory_store` cache are per-process; run one web process or use a shared cache (production uses Solid Cache) and set `MCP_SCHEDULER=0` on extra processes. Production uses the `:async` Active Job adapter.
- Only the `http` (Streamable HTTP) transport is supported upstream. `tools/list` with a slow upstream can block for the read timeout (30 s) once per minute per stale server.

## Tests and the mock upstream

```sh
bin/rails test
```

Manual end-to-end with the bundled mock server:

```sh
ruby script/mock_mcp_server.rb 9292                       # MOCK_SSE=1 for SSE replies, MOCK_TOKEN=x to require auth
ALLOW_PRIVATE_UPSTREAMS=true bin/dev                      # in another terminal
```

Enable the seeded `example` server (UI toggle), create a token, then:

```sh
curl -s localhost:3000/mcp -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
curl -s localhost:3000/mcp -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"example__echo","arguments":{"text":"hi"}}}'
```

## Docker

```sh
docker build -t mcp-gateway .
docker run -p 3000:3000 -e RAILS_MASTER_KEY=... -e ADMIN_EMAIL=... -e ADMIN_PASSWORD=... \
  -e AR_ENCRYPTION_PRIMARY_KEY=... -e AR_ENCRYPTION_DETERMINISTIC_KEY=... -e AR_ENCRYPTION_KEY_DERIVATION_SALT=... \
  -v mcp_storage:/rails/storage mcp-gateway
```

(Dockerfile build not verified in this environment.) Production forces SSL; terminate TLS at a proxy.
