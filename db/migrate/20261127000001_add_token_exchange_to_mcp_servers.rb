class AddTokenExchangeToMcpServers < ActiveRecord::Migration[8.1]
  def change
    change_table :mcp_servers, bulk: true do |t|
      t.string :exchange_issuer          # token exchange server (OIDC issuer); blank = KEYCLOAK_ISSUER
      t.string :exchange_client_id       # blank = GATEWAY_CLIENT_ID
      t.text :exchange_client_secret     # encrypted; blank = GATEWAY_CLIENT_SECRET
      t.string :exchange_audience        # exact aud of the exchanged token, e.g. mcp-orders
      t.string :exchange_scope           # scopes always requested (e.g. the audience scope)
      t.string :default_tool_scope       # required scope for tools without a per-tool entry
      t.json :tool_scopes                # { "tool_name" => "scope" }
    end
  end
end
