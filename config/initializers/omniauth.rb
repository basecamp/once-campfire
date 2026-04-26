Rails.application.config.middleware.use OmniAuth::Builder do
  # OIDC Providers (Keycloak, Okta, Azure AD, Google Workspace)
  OidcConfiguration.providers.each do |provider_config|
    provider :openid_connect,
      name: provider_config.fetch(:strategy),
      scope: provider_config.fetch(:scope),
      response_type: :code,
      issuer: provider_config.fetch(:issuer),
      discovery: true,
      client_auth_method: provider_config.fetch(:client_auth_method),
      client_options: {
        identifier: provider_config.fetch(:client_id),
        secret: provider_config.fetch(:client_secret),
        redirect_uri: provider_config.fetch(:redirect_uri)
      }
  end
end

OmniAuth.config.logger = Rails.logger

OmniAuth.config.on_failure = Proc.new do |env|
  OmniAuth::FailureEndpoint.new(env).redirect_to_failure
end
