module SsoHelper
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
end
