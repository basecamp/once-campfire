require "test_helper"

class OidcConfigurationTest < ActiveSupport::TestCase
  test "returns no providers when OIDC_PROVIDERS is unset" do
    assert_equal [], OidcConfiguration.providers(env: {})
  end

  test "builds multiple providers with expected strategy names" do
    providers = OidcConfiguration.providers(
      env: base_env.merge(
        "OIDC_PROVIDERS" => "google, azure_ad"
      )
    )

    assert_equal %w[oidc_google oidc_azure_ad], providers.map { _1.fetch(:strategy) }
    assert_equal [ "Google", "Azure Ad" ], providers.map { _1.fetch(:display_name) }
    assert_equal [ %w[openid email profile], %w[openid profile] ], providers.map { _1.fetch(:scope) }
  end

  test "uses provider_name when supplied" do
    providers = OidcConfiguration.providers(
      env: base_env.merge(
        "OIDC_PROVIDERS" => "keycloak",
        "OIDC_KEYCLOAK_ISSUER" => "https://idp.example.test/realms/campfire",
        "OIDC_KEYCLOAK_CLIENT_ID" => "campfire",
        "OIDC_KEYCLOAK_CLIENT_SECRET" => "secret",
        "OIDC_KEYCLOAK_REDIRECT_URI" => "https://chat.example.test/auth/oidc/callback",
        "OIDC_KEYCLOAK_PROVIDER_NAME" => "BloxWeaver OIDC"
      )
    )

    assert_equal [ "oidc" ], providers.map { _1.fetch(:strategy) }
    assert_equal [ "BloxWeaver OIDC" ], providers.map { _1.fetch(:display_name) }
  end

  test "reads optional end-session endpoint" do
    providers = OidcConfiguration.providers(
      env: base_env.merge(
        "OIDC_PROVIDERS" => "keycloak",
        "OIDC_KEYCLOAK_ISSUER" => "https://idp.example.test/realms/campfire",
        "OIDC_KEYCLOAK_CLIENT_ID" => "campfire",
        "OIDC_KEYCLOAK_CLIENT_SECRET" => "secret",
        "OIDC_KEYCLOAK_REDIRECT_URI" => "https://chat.example.test/auth/oidc/callback",
        "OIDC_KEYCLOAK_END_SESSION_ENDPOINT" => "https://idp.example.test/logout"
      )
    )

    assert_equal "https://idp.example.test/logout", providers.first.fetch(:end_session_endpoint)
  end

  test "raises when provider key is invalid" do
    error = assert_raises ArgumentError do
      OidcConfiguration.providers(env: base_env.merge("OIDC_PROVIDERS" => "Google-SSO"))
    end

    assert_match "Invalid OIDC provider key", error.message
  end

  test "raises when provider key is duplicated" do
    error = assert_raises ArgumentError do
      OidcConfiguration.providers(env: base_env.merge("OIDC_PROVIDERS" => "google,google"))
    end

    assert_match "Duplicate OIDC provider keys", error.message
  end

  test "raises when a required provider setting is missing" do
    env = base_env.merge("OIDC_PROVIDERS" => "google")
    env.delete("OIDC_GOOGLE_CLIENT_SECRET")

    error = assert_raises ArgumentError do
      OidcConfiguration.providers(env:)
    end

    assert_match "OIDC_GOOGLE_CLIENT_SECRET is required", error.message
  end

  test "raises when redirect uri callback path is invalid" do
    env = base_env.merge("OIDC_PROVIDERS" => "google", "OIDC_GOOGLE_REDIRECT_URI" => "https://chat.example.test/callback")

    error = assert_raises ArgumentError do
      OidcConfiguration.providers(env:)
    end

    assert_match "must use /auth/<provider>/callback", error.message
  end

  test "raises when redirect uris map to duplicate strategy names" do
    env = base_env.merge(
      "OIDC_PROVIDERS" => "google,azure_ad",
      "OIDC_GOOGLE_REDIRECT_URI" => "https://chat.example.test/auth/oidc/callback",
      "OIDC_AZURE_AD_REDIRECT_URI" => "https://chat.example.test/auth/oidc/callback"
    )

    error = assert_raises ArgumentError do
      OidcConfiguration.providers(env:)
    end

    assert_match "duplicate strategy names", error.message
  end

  private
    def base_env
      {
        "OIDC_GOOGLE_ISSUER" => "https://accounts.google.com",
        "OIDC_GOOGLE_CLIENT_ID" => "google-client-id",
        "OIDC_GOOGLE_CLIENT_SECRET" => "google-client-secret",
        "OIDC_GOOGLE_REDIRECT_URI" => "https://chat.example.test/auth/oidc_google/callback",
        "OIDC_GOOGLE_SCOPE" => "openid email profile",
        "OIDC_AZURE_AD_ISSUER" => "https://login.microsoftonline.com/example/v2.0",
        "OIDC_AZURE_AD_CLIENT_ID" => "azure-client-id",
        "OIDC_AZURE_AD_CLIENT_SECRET" => "azure-client-secret",
        "OIDC_AZURE_AD_REDIRECT_URI" => "https://chat.example.test/auth/oidc_azure_ad/callback",
        "OIDC_AZURE_AD_SCOPE" => "openid,profile"
      }
    end
end
