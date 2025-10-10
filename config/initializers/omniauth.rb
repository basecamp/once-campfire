# Only configure OIDC if the required environment variables are present
if ENV['OIDC_ISSUER'].present? && ENV['OIDC_CLIENT_ID'].present? && ENV['OIDC_CLIENT_SECRET'].present?
  # Configure OmniAuth
  OmniAuth.config.allowed_request_methods = [:post, :get]
  OmniAuth.config.silence_get_warning = true
  
  # Patch for WordPress/miniOrange OIDC compatibility
  # WordPress/miniOrange doesn't return proper OIDC ID tokens, so we use userinfo endpoint instead
  require 'omniauth/strategies/openid_connect'
  
  class OmniAuth::Strategies::OpenIDConnect
    # Skip ID token completely for non-standard providers
    def decode_id_token(id_token)
      return nil if id_token.nil?
      
      begin
        # Try standard decoding first
        ::OpenIDConnect::ResponseObject::IdToken.decode(
          id_token,
          public_key_or_secret
        )
      rescue => e
        # WordPress/miniOrange returns invalid ID tokens, just return nil and use userinfo
        Rails.logger.warn "OIDC ID Token validation failed: #{e.message}, using userinfo endpoint instead"
        nil
      end
    end
    
    # Skip ID token verification for non-standard providers
    def verify_id_token!(id_token)
      return true if id_token.nil?
      id_token.verify!(issuer: options.issuer, client_id: options.client_options.identifier)
    rescue => e
      Rails.logger.warn "OIDC ID Token verification skipped: #{e.message}"
      true
    end
    
    # Override user_info to work without ID token
    def user_info
      return @user_info if @user_info
      
      if access_token.access_token
        @user_info = access_token.userinfo!
      else
        # Fallback: make direct request to userinfo endpoint
        conn = Faraday.new(url: options.client_options[:userinfo_endpoint]) do |b|
          b.request :url_encoded
          b.adapter Faraday.default_adapter
        end
        
        response = conn.get do |req|
          req.headers['Authorization'] = "Bearer #{access_token.access_token}"
        end
        
        @user_info = ::OpenIDConnect::ResponseObject::UserInfo.new(JSON.parse(response.body))
      end
      
      @user_info
    rescue => e
      Rails.logger.error "OIDC UserInfo failed: #{e.message}"
      raise e
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
      uid_field: 'email',  # Use email as UID since 'sub' might not be available
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

