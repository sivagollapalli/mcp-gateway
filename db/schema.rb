# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2025_01_01_000001) do
  create_table "call_logs", force: :cascade do |t|
    t.integer "mcp_server_id"
    t.string "tool_name"
    t.integer "gateway_token_id"
    t.string "status", null: false
    t.integer "duration_ms"
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_call_logs_on_created_at"
    t.index ["gateway_token_id"], name: "index_call_logs_on_gateway_token_id"
    t.index ["mcp_server_id"], name: "index_call_logs_on_mcp_server_id"
    t.index ["status"], name: "index_call_logs_on_status"
  end

  create_table "gateway_tokens", force: :cascade do |t|
    t.string "name", null: false
    t.string "token_digest", null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_gateway_tokens_on_token_digest", unique: true
  end

  create_table "mcp_servers", force: :cascade do |t|
    t.string "name", null: false
    t.string "url", null: false
    t.string "transport", default: "http", null: false
    t.string "auth_type", default: "none", null: false
    t.text "auth_token"
    t.boolean "enabled", default: true, null: false
    t.text "description"
    t.string "last_status", default: "unknown", null: false
    t.text "last_error"
    t.datetime "last_checked_at"
    t.integer "tools_count", default: 0, null: false
    t.json "tools_cache"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_mcp_servers_on_name", unique: true
  end

  create_table "tool_policies", force: :cascade do |t|
    t.integer "mcp_server_id", null: false
    t.string "tool_name", null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_server_id", "tool_name"], name: "index_tool_policies_on_mcp_server_id_and_tool_name", unique: true
    t.index ["mcp_server_id"], name: "index_tool_policies_on_mcp_server_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "call_logs", "gateway_tokens"
  add_foreign_key "call_logs", "mcp_servers"
  add_foreign_key "tool_policies", "mcp_servers"
end
