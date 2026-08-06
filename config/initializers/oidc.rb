require "oidc"

Oidc.configuration = Oidc::Configuration.new

if Oidc.production_https?
  Rails.application.config.assume_ssl = Oidc.built_in_tls?
  Rails.application.config.force_ssl = true
  if Oidc.external_https?
    Rails.application.config.ssl_options = Rails.application.config.ssl_options.deep_merge(
      redirect: { exclude: ->(request) { Oidc::HEALTH_PATHS.include?(request.path) } }
    )
  end
end

if Oidc.production_https? && Oidc.built_in_tls?
  Rails.application.config.hosts.replace(Oidc.tls_domains)
  blocked_host_body = "Use a configured TLS host"
  Rails.application.config.host_authorization = Rails.application.config.host_authorization.merge(
    response_app: ->(_env) do
      [
        421,
        Oidc.security_headers(
          "cache-control" => "no-store",
          "content-length" => blocked_host_body.bytesize.to_s,
          "content-type" => "text/plain"
        ),
        [ blocked_host_body ]
      ]
    end
  )
end

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
