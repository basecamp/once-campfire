module SsoHelper
  BACKLIT_ACCOUNT_SETTINGS_PATH = "/users/edit".freeze

  def sso_enabled?
    oidc_enabled?
  end

  def oidc_providers
    @oidc_providers ||= OidcConfiguration.providers
  end

  def oidc_enabled?
    oidc_providers.any?
  end

  def password_registration_enabled?
    !ENV["DISABLE_PASSWORD_REGISTRATION"].to_s.downcase.in?(%w[ true 1 yes ])
  end

  # Backlit Devise account settings (name, email, password). Built from the OIDC issuer.
  def backlit_account_settings_url
    issuer = ENV["OIDC_BACKLIT_ISSUER"].to_s.strip.presence
    return if issuer.blank?

    "#{issuer.delete_suffix("/")}#{BACKLIT_ACCOUNT_SETTINGS_PATH}"
  end
end
