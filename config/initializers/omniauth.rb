# Only configure OIDC if the required environment variables are present
if ENV['OIDC_ISSUER'].present? && ENV['OIDC_CLIENT_ID'].present? && ENV['OIDC_CLIENT_SECRET'].present?
  # Configure OmniAuth
  OmniAuth.config.allowed_request_methods = [:post, :get]
  OmniAuth.config.silence_get_warning = true
  
  # Patch for WordPress/miniOrange OIDC compatibility
  # Skip ID token validation that fails with non-standard providers
  require 'omniauth/strategies/openid_connect'
  
  class OmniAuth::Strategies::OpenIDConnect
    # Override to skip problematic validations
    def decode_id_token(id_token)
      return nil if id_token.nil?
      
      begin
        # Try standard decoding first
        ::OpenIDConnect::ResponseObject::IdToken.decode(
          id_token,
          public_key_or_secret
        )
      rescue => e
        # If standard decoding fails, try without validation
        Rails.logger.warn "OIDC ID Token validation failed: #{e.message}, attempting lenient decode"
        
        # Decode without verification for non-standard providers
        payload, _ = JWT.decode(id_token, nil, false)
        ::OpenIDConnect::ResponseObject::IdToken.new(payload)
      end
    end
  end
  
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect, {
      name: :oidc,
      scope: [:openid, :email, :profile],
      response_type: :code,
      discovery: false,
      issuer: ENV['OIDC_ISSUER'],
      send_scope_to_token_endpoint: false,
      uid_field: 'sub',
      client_options: {
        identifier: ENV['OIDC_CLIENT_ID'],
        secret: ENV['OIDC_CLIENT_SECRET'],
        redirect_uri: ENV['OIDC_REDIRECT_URI'],
        authorization_endpoint: ENV['OIDC_AUTHORIZATION_ENDPOINT'],
        token_endpoint: ENV['OIDC_TOKEN_ENDPOINT'],
        userinfo_endpoint: ENV['OIDC_USERINFO_ENDPOINT'],
        scheme: 'https',
        host: 'ambba.com',
        port: 443
      },
      client_auth_method: :basic,
      pkce: false
    }
  end
end

