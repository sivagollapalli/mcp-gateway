# OAuth discovery documents. Unauthenticated by design (clients fetch them before logging in).
class WellKnownController < ActionController::API
  before_action :require_oidc
  after_action { response.set_header("Cache-Control", "public, max-age=300") }

  # RFC 9728. This is the first thing MCP clients fetch.
  def protected_resource
    render json: {
      resource: Oidc.config.resource_url,
      authorization_servers: [ Oidc.config.issuer ],
      scopes_supported: Oidc::Config::SUPPORTED_SCOPES,
      bearer_methods_supported: [ "header" ]
    }
  end

  # RFC 8414. Endpoints are copied verbatim from the realm's discovery document.
  def authorization_server
    meta = Oidc.provider.metadata
    return head :service_unavailable unless meta # discovery never loaded (fail closed)

    doc = {
      issuer: meta["issuer"],
      authorization_endpoint: meta["authorization_endpoint"],
      token_endpoint: meta["token_endpoint"],
      registration_endpoint: meta["registration_endpoint"],
      jwks_uri: meta["jwks_uri"],
      scopes_supported: Oidc::Config::SUPPORTED_SCOPES,
      response_types_supported: [ "code" ],
      grant_types_supported: (Array(meta["grant_types_supported"]) & %w[authorization_code refresh_token]).presence || [ "authorization_code" ],
      code_challenge_methods_supported: [ "S256" ],
      token_endpoint_auth_methods_supported: [ "none" ]
    }
    doc[:revocation_endpoint] = meta["revocation_endpoint"] if meta["revocation_endpoint"]
    render json: doc
  end

  private

  def require_oidc
    head :not_found unless Oidc.enabled?
  end
end
