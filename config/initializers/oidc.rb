# Fail fast: when OIDC is configured, a real server refuses to start unless Keycloak's
# discovery document and JWKS are reachable. Not run for tests, rake tasks or asset
# precompilation (set OIDC_BOOT_CHECK=1 to force).
Rails.application.config.after_initialize do
  next unless Oidc.enabled?
  next unless ENV["OIDC_BOOT_CHECK"] == "1" || (defined?(Rails::Server) && !Rails.env.test?)

  begin
    Oidc.boot!
  rescue Oidc::ConfigurationError => e
    warn "[oidc] FATAL: #{e.message}"
    abort "Refusing to start: OIDC configuration invalid or Keycloak unreachable."
  end
end
