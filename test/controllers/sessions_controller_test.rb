require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "OIDC sign-in establishes a secure browser flow binding" do
    configure_oidc
    host! Oidc.configuration.redirect_host
    https!

    get new_session_url

    browser_cookie = Array(response.headers.fetch("set-cookie")).find { _1.start_with?("#{Oidc::BROWSER_COOKIE}=") }
    assert_match(/;\s*secure/i, browser_cookie)
    assert_match(/;\s*httponly/i, browser_cookie)
    assert_match(/;\s*samesite=lax/i, browser_cookie)
  end

  test "trusted non-default proxy port is used for authentication URLs and the saved return URL" do
    configure_oidc(
      "DISABLE_SSL" => "true",
      "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16",
      "HTTPS_PORT" => "8443",
      "OIDC_REDIRECT_URI" => "https://campfire.example.com:8443/auth/openid_connect/callback"
    )
    host! "campfire.example.com"
    proxy_environment = {
      "REMOTE_ADDR" => "10.20.1.2",
      "HTTP_X_FORWARDED_FOR" => "198.51.100.20",
      "HTTP_X_FORWARDED_PROTO" => "https",
      "HTTP_X_FORWARDED_PORT" => "8443"
    }

    get room_path(rooms(:watercooler)), env: proxy_environment

    assert_redirected_to "https://campfire.example.com:8443/session/new"

    post session_path, params: {
      email_address: users(:david).email_address,
      password: "secret123456"
    }, env: proxy_environment

    assert_redirected_to "https://campfire.example.com:8443/rooms/#{rooms(:watercooler).id}"
  end

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

  test "create with valid credentials" do
    assert_difference -> { Session.count }, +1 do
      post session_url, params: { email_address: "david@37signals.com", password: "secret123456" }
    end

    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]
  end

  test "create normalizes the email lookup" do
    post session_url, params: {
      email_address: "\tDAVID@37SIGNALS.COM \n", password: "secret123456"
    }

    assert_redirected_to root_url
    assert_equal users(:david), Session.find_by!(token: parsed_cookies.signed[:session_token]).user
  end

  test "create with invalid credentials" do
    post session_url, params: { email_address: "david@37signals.com", password: "wrong" }

    assert_response :unauthorized
    assert_nil parsed_cookies.signed[:session_token]
  end

  test "password login returns service unavailable before verification when the limiter returns nil" do
    Rails.cache.stubs(:increment).returns(nil)
    User.any_instance.expects(:authenticate_password).never

    post session_url, params: { email_address: users(:david).email_address, password: "secret123456" }

    assert_response :service_unavailable
    assert_equal Oidc::POLICY_UNAVAILABLE_MESSAGE, response.body
  end

  test "password login returns service unavailable before verification when the limiter errors" do
    Rails.cache.stubs(:increment).raises(Timeout::Error, "cache timeout")
    User.any_instance.expects(:authenticate_password).never

    post session_url, params: { email_address: users(:david).email_address, password: "secret123456" }

    assert_response :service_unavailable
    assert_equal Oidc::POLICY_UNAVAILABLE_MESSAGE, response.body
  end

  test "password login returns service unavailable before verification for a malformed counter" do
    Rails.cache.stubs(:increment).returns("1")
    User.any_instance.expects(:authenticate_password).never

    post session_url, params: { email_address: users(:david).email_address, password: "secret123456" }

    assert_response :service_unavailable
  end

  test "password login preserves the too-many-requests response" do
    SessionsController::PASSWORD_ATTEMPT_LIMIT.times do
      post session_url, params: { email_address: users(:david).email_address, password: "wrong" }
      assert_response :unauthorized
    end

    assert_no_difference -> { Session.count } do
      post session_url, params: { email_address: users(:david).email_address, password: "secret123456" }
    end

    assert_response :too_many_requests
  end

  test "required OIDC mode rejects password login for ordinary users" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(true)

    post session_url, params: { email_address: users(:david).email_address, password: "secret123456" }

    assert_response :unauthorized
    assert_nil parsed_cookies.signed[:session_token]
  end

  test "required OIDC mode permits the configured administrator recovery account" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => " JASON@37SIGNALS.COM ")
    Oidc::Activation.stubs(:ready?).returns(true)
    host! Oidc.configuration.redirect_host
    https!

    post session_url, params: { email_address: users(:jason).email_address, password: "secret123456" }

    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]
  end

  test "required-mode recovery login also fails closed when limiting is unavailable" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(true)
    Rails.cache.stubs(:increment).returns(nil)
    User.any_instance.expects(:authenticate_password).never

    post session_url, params: { email_address: users(:jason).email_address, password: "secret123456" }

    assert_response :service_unavailable
    assert_nil parsed_cookies.signed[:session_token]
  end

  test "required OIDC mode does not permit a non-administrator recovery account" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jz).email_address)

    post session_url, params: { email_address: users(:jz).email_address, password: "secret123456" }

    assert_response :unauthorized
    assert_nil parsed_cookies.signed[:session_token]
  end

  test "required OIDC mode presents SSO without the password form" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(true)

    get new_session_url

    assert_select "form[action='#{openid_connect_path}']"
    assert_select "input[name='email_address']", count: 0
    assert_select "a[href='#{new_session_path(local: 1)}']", text: "Administrator recovery sign-in"
  end

  test "administrator recovery view presents both sign-in methods" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(true)

    get new_session_url(local: 1)

    assert_select "form[action='#{openid_connect_path}']"
    assert_select "input[name='email_address']", count: 1
  end

  test "required OIDC mode without a recovery account still presents SSO repair" do
    configure_oidc("OIDC_MODE" => "required")

    get new_session_url(local: 1)

    assert_response :success
    assert_select "form[action='#{openid_connect_path}']"
    assert_select "input[name='email_address']", count: 0
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

  test "destroy removes the push subscription for the device" do
    sign_in :david

    assert_difference -> { users(:david).push_subscriptions.count }, -1 do
      delete session_url, params: { push_subscription_endpoint: push_subscriptions(:david_chrome).endpoint }
    end

    assert_redirected_to root_url
    assert_not cookies[:session_token].present?
  end
end
