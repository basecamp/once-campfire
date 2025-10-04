# Only configure OIDC if the required environment variables are present
if ENV['OIDC_ISSUER'].present? && ENV['OIDC_CLIENT_ID'].present? && ENV['OIDC_CLIENT_SECRET'].present?
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect, {
      name: :oidc,
      scope: [:openid, :email, :profile],
      response_type: :code,
      discovery: true,
      issuer: ENV['OIDC_ISSUER'],
      client_options: {
        identifier: ENV['OIDC_CLIENT_ID'],
        secret: ENV['OIDC_CLIENT_SECRET'],
        redirect_uri: ENV.fetch('OIDC_REDIRECT_URI', "#{Rails.application.routes.url_helpers.root_url}auth/oidc/callback"),
        authorization_endpoint: ENV['OIDC_AUTHORIZATION_ENDPOINT'],
        token_endpoint: ENV['OIDC_TOKEN_ENDPOINT'],
        userinfo_endpoint: ENV['OIDC_USERINFO_ENDPOINT']
      }.compact
    }
  end
end

