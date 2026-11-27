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

## OIDC authentication with Keycloak (user leg)
Setting `KEYCLOAK_ISSUER` switches `/mcp` from static gateway tokens to **OAuth 2.0 / OIDC bearer JWTs issued by Keycloak** (Authorization Code + PKCE S256, clients register themselves via RFC 7591). Without it, the static-token behaviour described above is unchanged. The gateway→upstream auth leg is not part of this work.

### Run it
```sh
docker compose up --build      # Keycloak on :8080 (realm `mcp` imported), gateway on :8081
claude mcp add --transport http mcp-gateway http://localhost:8081/mcp
```
Then in Claude Code run `/mcp`, pick `mcp-gateway`, choose **Login**. The browser opens Keycloak; sign in as `test-user` / `test-password`, accept the consent screen, and call the `whoami` tool: it returns your `sub` and granted scopes.

Keycloak admin console: http://localhost:8080 (`admin` / `admin`, dev only). If port 8080 or 8081 is taken, set `KEYCLOAK_PORT` / `GATEWAY_PORT` (the issuer and public URL follow automatically).

`script/oidc_e2e.py [gateway_url] [scopes]` replays the whole flow without a browser (discovery, DCR, PKCE, login, consent, token, `whoami`) and checks that an authorization request without PKCE is refused.

### Environment (see `.env.example`)
| Variable | Default | Purpose |
|---|---|---|
| `KEYCLOAK_ISSUER` | unset (OIDC off) | Exact issuer, e.g. `http://localhost:8080/realms/mcp`. No trailing slash. Plain `http` is only accepted for localhost |
| `GATEWAY_AUDIENCE` | `mcp-gateway` | Required `aud` value |
| `CLOCK_LEEWAY` | `30` | Seconds of tolerance for `exp` / `nbf` (0-300) |
| `GATEWAY_PUBLIC_URL` | required in OIDC mode | Public base URL; becomes `resource` (`<url>/mcp`) in the protected-resource metadata and the `resource_metadata` challenge |
| `KEYCLOAK_INTERNAL_URL` | unset | Origin used to *fetch* discovery and JWKS when the issuer host is not reachable from the gateway (compose sets `http://keycloak:8080`). Advertised endpoints are not rewritten |
| `JWKS_MIN_REFETCH_INTERVAL` | `10` | Minimum seconds between JWKS refetches caused by unknown `kid`s |

### What the gateway does
* **Startup**: fetches `{issuer}/.well-known/openid-configuration`, checks `issuer` equals `KEYCLOAK_ISSUER` byte for byte, fetches the JWKS and caches RS256 signing keys by `kid`. If either fetch fails the process exits (`rails server` only; tests, rake tasks and asset precompilation skip it, or force it with `OIDC_BOOT_CHECK=1`).
* **Discovery**: `GET /.well-known/oauth-protected-resource` (RFC 9728, also under `/mcp`) lists Keycloak as `authorization_servers`. `GET /.well-known/oauth-authorization-server` (RFC 8414, also under `/mcp`) copies the authorize, token, registration and JWKS endpoints verbatim from the realm's discovery document.
* **`POST /mcp` and `GET /mcp`** run this pipeline before any JSON-RPC handling:
  1. `Authorization: Bearer <token>` is required, anything else is a 401.
  2. Only `kid` and `alg` are read from the header. `alg` must be in the pinned list `["RS256"]` (`none`, `HS256`, `RS512`, lower-case variants are rejected). `crit` headers are rejected, `jwk`/`jku`/`x5u` are ignored.
  3. `kid` is looked up in the cached JWKS. On a miss the JWKS is refetched once (rate limited) and the lookup repeated. Unknown means reject. An empty cache also rejects.
  4. The RS256 signature is verified with the resolved key.
  5. Claims: `iss` string-equal to the issuer; `aud` (string or array) contains exactly `mcp-gateway`; `exp` required, `nbf` checked, both with the leeway; `sub` and `jti` required; then scopes.
  6. 401 `Bearer error="invalid_token"` for crypto/claim failures, 403 `Bearer error="insufficient_scope", scope="..."` when the token is valid but lacks scopes. A missing or non-bearer header gets a 401 without an `error` code (RFC 6750 section 3.1). All challenges carry `resource_metadata`.
  7. On success `sub`, `scopes` and `jti` are attached to the request (`@principal`). Logs contain `sub` and `jti` only, never the token.
* **Scopes**: every `/mcp` request needs `mcp:read`; `tools/call` (including `whoami`) also needs `mcp:tools:execute`.
* **Tool `whoami`** is listed and callable for OIDC callers and returns `{ "sub": ..., "scopes": [...] }`.
* No call to Keycloak happens per request (no introspection or userinfo). The only network calls are boot and the rate-limited refetch on an unknown `kid`. Tokens are never forwarded upstream.

### Keycloak realm (`keycloak/realm-mcp.json`)
Realm `mcp`; issuer `http://localhost:8080/realms/mcp` (pinned in compose with `KC_HOSTNAME`). Access tokens are RS256 with a 10 minute lifetime. Client scope `mcp-api` (realm default scope) has the audience mapper for `mcp-gateway`. `mcp:read` and `mcp:tools:execute` are realm *optional* scopes. Client policy `enforce-pkce-public-clients` applies the `pkce-enforcer` executor (auto-configure, S256) to every public client, which includes anonymously registered ones. Test user: `test-user` / `test-password`, with the realm's default roles. Claude Code requests `offline_access` (Keycloak advertises it), and the token exchange fails with "Offline tokens not allowed" if the user lacks that role.

Dynamic Client Registration is **anonymous** for development (Trusted Hosts restricts redirect URIs to `localhost` / `127.0.0.1`, Consent Required is on). **For production switch to initial access tokens**: remove the `subType: anonymous` policies, create an initial access token in *Clients > Initial access token*, and give it to whoever registers clients. Also replace the dev admin password, set `sslRequired` to `external` or `all`, use HTTPS issuers, and set a real `SECRET_KEY_BASE`.

### Decisions and deviations from the spec
* **Existing Rails app, not a new service.** OIDC is added to this app. `/mcp` accepts *either* Keycloak JWTs (when `KEYCLOAK_ISSUER` is set) *or* the legacy static tokens (when it is not), never both, so the validation pipeline has a single entry path. In OIDC mode a static token gets a 401.
* **No separate "scope" mapper.** Keycloak has no protocol mapper type for the `scope` claim; it writes the claim itself from the client scopes that have `include.in.token.scope=true`. `mcp-api`, `mcp:read` and `mcp:tools:execute` all set it. The audience mapper is the only mapper in `mcp-api`.
* **The audience mapper is also on `mcp:read` and `mcp:tools:execute`.** Keycloak's anonymous registration gives a client only the scopes it asked for (plus `basic`), not the realm default scopes, when the request has a `scope` parameter (Claude Code sends one). Without the mapper on the `mcp:*` scopes those tokens would have no `aud` and be rejected. Any token with an `mcp:*` scope therefore carries `aud: mcp-gateway`.
* **`aud` is the fixed string `mcp-gateway`, not the resource URL.** Clients still send RFC 8707 `resource=<gateway url>`; Keycloak ignores it for audience purposes and the mapper decides.
* **`jti` and `sub` are required** in addition to the listed claims, so every accepted request can be logged by `jti` and `sub`.
* **JWKS refetch on unknown `kid` is rate limited** (default one per 10 s) so forged `kid`s cannot be used to hammer Keycloak. A refetch that fails keeps the old keys.
* **JWKS filtering**: only RSA keys with `use` `sig` (or unset), `alg` RS256 (or unset) and at least 2048 bits are loaded.
* **Fetch origin override** (`KEYCLOAK_INTERNAL_URL`) exists because inside Docker `localhost:8080` is not Keycloak. Only the fetch is rewritten; issuer and advertised endpoints stay verbatim.
* **Authorization-server metadata** advertises only `code` / `authorization_code` / `refresh_token`, `S256` and `none` client auth, narrower than Keycloak's own document. `scopes_supported` lists only the two `mcp:*` scopes.
* **`mcp:read` must be granted.** Because it is an optional scope, clients that do not request it get a 403 `insufficient_scope` whose challenge names the scope, which MCP clients use to re-authorize. The protected-resource metadata lists both scopes so clients request them.
* **Rate limiting** from the existing Rack::Attack setup still applies to `/mcp` (it keys on the Authorization header hash). No new rate limiting was added.
* **Production database config**: `config/database.yml` had the production `database:` paths commented out, so the container could not boot. They now point at `storage/production*.sqlite3` (override with `DATABASE_URL` as before). This was needed for `docker compose up`.
* **Compose ports** can be overridden (`KEYCLOAK_PORT`, `GATEWAY_PORT`); the defaults are the ones in the spec (8080, 8081).
* The gateway runs the production image, so `docker compose` uses an insecure development `SECRET_KEY_BASE` unless you set one.
* **Verified**: Claude Code `/mcp` → Authenticate → browser login → `whoami` returns `sub` and scopes, against Keycloak 26.4.7 under `docker compose`. `script/oidc_e2e.py` covers the same flow without a browser.
* Out of scope and not built: gateway→upstream client credentials, token exchange, policy engine beyond scopes, new rate limiting, multi-tenancy, session resumption.
