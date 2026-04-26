require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  ALLOWED_BROWSER    = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
  DISALLOWED_BROWSER = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/114.0"

  test "new" do
    get new_session_url
    assert_response :success
  end

  test "new redirects to first run when no users exist" do
    User.destroy_all

    get new_session_url

    assert_redirected_to first_run_url
  end

  test "new denied with incompatible browser" do
    get new_session_url, env: { "HTTP_USER_AGENT" => DISALLOWED_BROWSER }
    assert_select "h1", /Upgrade to a supported web browser/
  end

  test "new allowed with compatible browser" do
    get new_session_url, env: { "HTTP_USER_AGENT" => ALLOWED_BROWSER }
    assert_select "h1", text: /Upgrade to a supported web browser/, count: 0
  end

  test "new in SSO-first mode does not render the secondary SSO panel" do
    original_oidc_providers = ENV["OIDC_PROVIDERS"]
    original_oidc_test_issuer = ENV["OIDC_TEST_ISSUER"]
    original_oidc_test_client_id = ENV["OIDC_TEST_CLIENT_ID"]
    original_oidc_test_client_secret = ENV["OIDC_TEST_CLIENT_SECRET"]
    original_oidc_test_redirect_uri = ENV["OIDC_TEST_REDIRECT_URI"]
    original_oidc_test_provider_name = ENV["OIDC_TEST_PROVIDER_NAME"]
    original_disable_password_registration = ENV["DISABLE_PASSWORD_REGISTRATION"]

    ENV["OIDC_PROVIDERS"] = "test"
    ENV["OIDC_TEST_ISSUER"] = "https://idp.example.test/realms/campfire"
    ENV["OIDC_TEST_CLIENT_ID"] = "test-client-id"
    ENV["OIDC_TEST_CLIENT_SECRET"] = "test-client-secret"
    ENV["OIDC_TEST_REDIRECT_URI"] = "https://campfire.example.test/auth/oidc_test/callback"
    ENV["OIDC_TEST_PROVIDER_NAME"] = "Test OIDC"
    ENV["DISABLE_PASSWORD_REGISTRATION"] = "true"

    get new_session_url

    assert_response :success
    assert_select "summary", text: "Sign in with email and password"
    assert_select "strong", text: "Or sign in with", count: 0
  ensure
    ENV["OIDC_PROVIDERS"] = original_oidc_providers
    ENV["OIDC_TEST_ISSUER"] = original_oidc_test_issuer
    ENV["OIDC_TEST_CLIENT_ID"] = original_oidc_test_client_id
    ENV["OIDC_TEST_CLIENT_SECRET"] = original_oidc_test_client_secret
    ENV["OIDC_TEST_REDIRECT_URI"] = original_oidc_test_redirect_uri
    ENV["OIDC_TEST_PROVIDER_NAME"] = original_oidc_test_provider_name
    ENV["DISABLE_PASSWORD_REGISTRATION"] = original_disable_password_registration
  end

  test "new uses configured OIDC provider label and callback-derived strategy" do
    original_oidc_providers = ENV["OIDC_PROVIDERS"]
    original_oidc_keycloak_issuer = ENV["OIDC_KEYCLOAK_ISSUER"]
    original_oidc_keycloak_client_id = ENV["OIDC_KEYCLOAK_CLIENT_ID"]
    original_oidc_keycloak_client_secret = ENV["OIDC_KEYCLOAK_CLIENT_SECRET"]
    original_oidc_keycloak_redirect_uri = ENV["OIDC_KEYCLOAK_REDIRECT_URI"]
    original_oidc_keycloak_provider_name = ENV["OIDC_KEYCLOAK_PROVIDER_NAME"]
    original_disable_password_registration = ENV["DISABLE_PASSWORD_REGISTRATION"]

    ENV["OIDC_PROVIDERS"] = "keycloak"
    ENV["OIDC_KEYCLOAK_ISSUER"] = "https://idp.example.test/realms/campfire"
    ENV["OIDC_KEYCLOAK_CLIENT_ID"] = "campfire"
    ENV["OIDC_KEYCLOAK_CLIENT_SECRET"] = "secret"
    ENV["OIDC_KEYCLOAK_REDIRECT_URI"] = "https://campfire.example.test/auth/oidc/callback"
    ENV["OIDC_KEYCLOAK_PROVIDER_NAME"] = "BloxWeaver OIDC"
    ENV["DISABLE_PASSWORD_REGISTRATION"] = "true"

    get new_session_url

    assert_response :success
    assert_select "button", text: "Sign in with BloxWeaver OIDC"
    assert_select "form[action='/auth/oidc']"
  ensure
    ENV["OIDC_PROVIDERS"] = original_oidc_providers
    ENV["OIDC_KEYCLOAK_ISSUER"] = original_oidc_keycloak_issuer
    ENV["OIDC_KEYCLOAK_CLIENT_ID"] = original_oidc_keycloak_client_id
    ENV["OIDC_KEYCLOAK_CLIENT_SECRET"] = original_oidc_keycloak_client_secret
    ENV["OIDC_KEYCLOAK_REDIRECT_URI"] = original_oidc_keycloak_redirect_uri
    ENV["OIDC_KEYCLOAK_PROVIDER_NAME"] = original_oidc_keycloak_provider_name
    ENV["DISABLE_PASSWORD_REGISTRATION"] = original_disable_password_registration
  end

  test "create with valid credentials" do
    assert_difference -> { Session.count }, +1 do
      post session_url, params: { email_address: "david@37signals.com", password: "secret123456" }
    end

    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]
  end

  test "create with invalid credentials" do
    post session_url, params: { email_address: "david@37signals.com", password: "wrong" }

    assert_response :unauthorized
    assert_nil parsed_cookies.signed[:session_token]
  end

  test "destroy" do
    sign_in :david
    session = users(:david).sessions.last

    assert_difference -> { Session.count }, -1 do
      delete session_url
    end

    assert_redirected_to root_url
    assert_not cookies[:session_token].present?
    assert_nil Session.find_by(id: session.id)
  end

  test "destroy redirects through OIDC provider logout for OIDC-backed sessions" do
    sign_in :david
    session = Session.find_by(token: parsed_cookies.signed[:session_token])
    session.update!(sso_provider: "oidc", oidc_id_token: "jwt-id-token")

    logout_url = "https://idp.example.test/logout?client_id=campfire"

    OidcLogout.expects(:logout_url_for).with(
      strategy: "oidc",
      id_token_hint: "jwt-id-token",
      post_logout_redirect_uri: root_url
    ).returns(logout_url)
    delete session_url

    assert_redirected_to logout_url
    assert_not cookies[:session_token].present?
    assert_nil Session.find_by(id: session.id)
  end

  test "destroy removes the push subscription for the device" do
    sign_in :david

    assert_difference -> { users(:david).push_subscriptions.count }, -1 do
      delete session_url, params: { push_subscription_endpoint: push_subscriptions(:david_chrome).endpoint }
    end

    assert_redirected_to root_url
    assert_not cookies[:session_token].present?
  end
end
