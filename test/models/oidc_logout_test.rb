require "test_helper"

class OidcLogoutTest < ActiveSupport::TestCase
  test "returns nil when provider strategy is unknown" do
    assert_nil OidcLogout.logout_url_for(
      strategy: "missing",
      post_logout_redirect_uri: "https://chat.example.test/",
      env: {}
    )
  end

  test "builds logout URL from configured end-session endpoint" do
    env = base_env.merge(
      "OIDC_PROVIDERS" => "keycloak",
      "OIDC_KEYCLOAK_END_SESSION_ENDPOINT" => "https://idp.example.test/logout"
    )

    logout_url = OidcLogout.logout_url_for(
      strategy: "oidc",
      post_logout_redirect_uri: "https://chat.example.test/",
      env: env
    )

    uri = URI.parse(logout_url)
    params = Rack::Utils.parse_nested_query(uri.query)

    assert_equal "https://idp.example.test/logout", "#{uri.scheme}://#{uri.host}#{uri.path}"
    assert_equal "campfire", params["client_id"]
    assert_equal "https://chat.example.test/", params["post_logout_redirect_uri"]
  end

  test "adds id_token_hint when provided" do
    env = base_env.merge(
      "OIDC_PROVIDERS" => "keycloak",
      "OIDC_KEYCLOAK_END_SESSION_ENDPOINT" => "https://idp.example.test/logout"
    )

    logout_url = OidcLogout.logout_url_for(
      strategy: "oidc",
      id_token_hint: "jwt-id-token",
      post_logout_redirect_uri: "https://chat.example.test/",
      env: env
    )

    params = Rack::Utils.parse_nested_query(URI.parse(logout_url).query)
    assert_equal "jwt-id-token", params["id_token_hint"]
  end

  test "discovers end-session endpoint from issuer metadata when not configured" do
    stub_request(:get, "https://idp.example.test/realms/campfire/.well-known/openid-configuration")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { end_session_endpoint: "https://idp.example.test/discovered-logout?foo=bar" }.to_json
      )

    logout_url = OidcLogout.logout_url_for(
      strategy: "oidc",
      post_logout_redirect_uri: "https://chat.example.test/",
      env: base_env.merge("OIDC_PROVIDERS" => "keycloak")
    )

    uri = URI.parse(logout_url)
    params = Rack::Utils.parse_nested_query(uri.query)

    assert_equal "https://idp.example.test/discovered-logout", "#{uri.scheme}://#{uri.host}#{uri.path}"
    assert_equal "bar", params["foo"]
    assert_equal "campfire", params["client_id"]
    assert_equal "https://chat.example.test/", params["post_logout_redirect_uri"]
  end

  private
    def base_env
      {
        "OIDC_KEYCLOAK_ISSUER" => "https://idp.example.test/realms/campfire",
        "OIDC_KEYCLOAK_CLIENT_ID" => "campfire",
        "OIDC_KEYCLOAK_CLIENT_SECRET" => "secret",
        "OIDC_KEYCLOAK_REDIRECT_URI" => "https://chat.example.test/auth/oidc/callback"
      }
    end
end
