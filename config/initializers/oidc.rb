require "oidc"

Oidc.configuration = Oidc::Configuration.new

if Oidc.enabled?
  require "action_dispatch/middleware/remote_ip"
  require "oidc/activation"
  require "oidc/authenticity_token_verifier"
  require "oidc/http_adapter"
  require "oidc/proxy_headers"
  require "oidc/request_guard"
  require "campfire_open_id_connect_strategy"

  attribution_proxy_ranges = Oidc::ProxyHeaders.attribution_proxy_ranges
  Rails.application.config.action_dispatch.trusted_proxies = attribution_proxy_ranges
  Rails.application.config.middleware.insert_before ActionDispatch::RemoteIp, Oidc::ProxyHeaders,
    trusted_proxy_ranges: attribution_proxy_ranges,
    allow_proxy_chain: Oidc.proxy_required?

  OpenIDConnect.logger = Rails.logger
  OpenIDConnect.http_config do |connection|
    connection.options.open_timeout = 5
    connection.options.timeout = 10
    connection.adapter Oidc::HTTPAdapter,
      allowed_hosts: Oidc.allowed_hosts,
      allow_private_network: Oidc.allow_private_network?
  end

  OmniAuth.config.logger = Logger.new(IO::NULL)
  OmniAuth.config.allowed_request_methods = [ :post ]
  OmniAuth.config.request_validation_phase = Oidc::AuthenticityTokenVerifier.new
  OmniAuth.config.on_failure = ->(env) { Oidc::SessionsController.action(:failure).call(env) }

  Rails.application.config.middleware.use Oidc::RequestGuard
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider CampfireOpenIdConnectStrategy,
      issuer: Oidc.issuer,
      discovery: true,
      scope: %i[ openid email profile ],
      response_type: :code,
      send_state: true,
      require_state: true,
      send_nonce: true,
      pkce: true,
      client_signing_alg: Oidc.signing_algorithm.to_sym,
      client_auth_method: Oidc.client_auth_method.to_sym,
      client_options: {
        identifier: Oidc.client_id,
        secret: Oidc.client_secret,
        redirect_uri: Oidc.redirect_uri
      }
  end
end
