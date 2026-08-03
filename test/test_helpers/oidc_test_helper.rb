module OidcTestHelper
  DEFAULT_OIDC_ENV = {
    "OIDC_MODE" => "optional",
    "OIDC_ISSUER" => "https://idp.example.com",
    "OIDC_CLIENT_ID" => "campfire",
    "OIDC_CLIENT_SECRET" => "client-secret",
    "OIDC_REDIRECT_URI" => "https://campfire.example.com/auth/openid_connect/callback",
    "TLS_DOMAIN" => "campfire.example.com"
  }.freeze

  def configure_oidc(overrides = {})
    @original_oidc_configuration ||= Oidc.configuration
    Oidc.configuration = Oidc::Configuration.new(DEFAULT_OIDC_ENV.merge(overrides.stringify_keys))
  end

  def reset_oidc_configuration
    if @original_oidc_configuration
      Oidc.configuration = @original_oidc_configuration
      @original_oidc_configuration = nil
    end
  end

  def oidc_auth(subject: "oidc-subject", email: "oidc@example.com", name: "OIDC User", id_token: "signed-id-token", claims: {})
    raw_info = {
      "iss" => Oidc.issuer,
      "sub" => subject,
      "aud" => Oidc.client_id,
      "exp" => 5.minutes.from_now.to_i,
      "iat" => Time.current.to_i,
      "nonce" => "nonce",
      "email" => email,
      "email_verified" => true,
      "name" => name
    }.merge(claims)

    OmniAuth::AuthHash.new(
      provider: "openid_connect",
      uid: subject,
      credentials: { id_token: },
      extra: { raw_info: }
    )
  end
end
