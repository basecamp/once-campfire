Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, {
    name: :oidc,
    scope: [:openid, :email, :profile],
    response_type: :code,
    discovery: true,
    issuer: ENV.fetch('OIDC_ISSUER'),
    client_options: {
      identifier: ENV.fetch('OIDC_CLIENT_ID'),
      secret: ENV.fetch('OIDC_CLIENT_SECRET'),
      redirect_uri: ENV.fetch('OIDC_REDIRECT_URI', "#{Rails.application.routes.url_helpers.root_url}auth/oidc/callback"),
      authorization_endpoint: ENV.fetch('OIDC_AUTHORIZATION_ENDPOINT', nil),
      token_endpoint: ENV.fetch('OIDC_TOKEN_ENDPOINT', nil),
      userinfo_endpoint: ENV.fetch('OIDC_USERINFO_ENDPOINT', nil)
    }.compact
  }
end

