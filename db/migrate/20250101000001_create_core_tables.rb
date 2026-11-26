class CreateCoreTables < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, :email, unique: true

    create_table :mcp_servers do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.string :transport, null: false, default: "http"
      t.string :auth_type, null: false, default: "none"
      t.text :auth_token
      t.boolean :enabled, null: false, default: true
      t.text :description
      t.string :last_status, null: false, default: "unknown"
      t.text :last_error
      t.datetime :last_checked_at
      t.integer :tools_count, null: false, default: 0
      t.json :tools_cache
      t.timestamps
    end
    add_index :mcp_servers, :name, unique: true

    create_table :tool_policies do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.string :tool_name, null: false
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :tool_policies, [ :mcp_server_id, :tool_name ], unique: true

    create_table :gateway_tokens do |t|
      t.string :name, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :gateway_tokens, :token_digest, unique: true

    create_table :call_logs do |t|
      t.references :mcp_server, foreign_key: true
      t.string :tool_name
      t.references :gateway_token, foreign_key: true
      t.string :status, null: false
      t.integer :duration_ms
      t.text :error
      t.datetime :created_at, null: false
    end
    add_index :call_logs, :created_at
    add_index :call_logs, :status
  end
end
