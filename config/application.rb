require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module McpGateway
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Gateway settings
    # Defaults to true in development only (local MCP servers); set ALLOW_PRIVATE_UPSTREAMS=false to block.
    config.x.gateway.allow_private_upstreams = ENV.fetch("ALLOW_PRIVATE_UPSTREAMS", Rails.env.development? ? "true" : "false") == "true"
    config.x.gateway.max_result_bytes = Integer(ENV.fetch("MCP_MAX_RESULT_BYTES", 100_000))
    config.x.gateway.max_description_chars = 2000
    config.x.gateway.stream_max_seconds = Integer(ENV.fetch("MCP_STREAM_MAX_SECONDS", 300)) # SSE streams are recycled (client reconnects)
    config.x.gateway.tools_ttl = 60 # seconds before a server's tool list is considered stale
    config.x.gateway.rate_limit = Integer(ENV.fetch("MCP_RATE_LIMIT", 120)) # requests/minute per token or IP

    # Active Record encryption. Set the three ENV keys in production
    # (generate with `bin/rails db:encryption:init`). In dev/test they are derived
    # from secret_key_base so nothing extra is needed.
    config.after_initialize do
      enc = config.active_record.encryption
      derive = ->(salt) { ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base).generate_key(salt, 32).unpack1("H*") }
      enc.primary_key = ENV["AR_ENCRYPTION_PRIMARY_KEY"] || derive.("ar-primary")
      enc.deterministic_key = ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"] || derive.("ar-deterministic")
      enc.key_derivation_salt = ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"] || derive.("ar-salt")
    end
  end
end
