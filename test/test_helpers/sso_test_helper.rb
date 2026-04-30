module SsoTestHelper
  def set_omniauth_auth(provider:, uid:, email:, name: "Test User", id_token: nil)
    auth_hash = OmniAuth::AuthHash.new(
      provider: provider.to_s,
      uid: uid,
      info: OmniAuth::AuthHash::InfoHash.new(
        email: email,
        name: name
      ),
      credentials: OmniAuth::AuthHash.new(
        id_token: id_token
      )
    )

    Rails.application.env_config["omniauth.auth"] = auth_hash
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[provider.to_sym] = auth_hash
  end

  def clear_omniauth_auth
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth.clear
    OmniAuth.config.test_mode = false
  end
end
