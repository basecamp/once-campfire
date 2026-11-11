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

  test "create with valid credentials" do
    assert_difference -> { Session.count }, +1 do
      post session_url, params: { email_address: "david@37signals.com", password: "secret123456" }
    end

    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]
  end

  test "create is refused when Sign in with Backlit is enabled" do
    with_backlit_sso_enabled do
      assert_no_difference -> { Session.count } do
        post session_url, params: { email_address: "david@37signals.com", password: "secret123456" }
      end

      assert_response :unauthorized
      assert_select "p", /Use Sign in with Backlit/
    end
  end

  test "new hides email and password when Sign in with Backlit is enabled" do
    with_backlit_sso_enabled do
      get new_session_url

      assert_response :success
      assert_select "button", text: /Sign in with Backlit/
      assert_select "summary", text: /Sign in with email and password/, count: 0
      assert_select "input[type=password]", count: 0
    end
  end

  test "create is refused when the password changes after it was checked" do
    user = User.find(users(:david).id)
    User.find(user.id).update!(password: "a new secret123456")
    User.stubs(:authenticate_by).returns(user)

    assert_no_difference -> { Session.count } do
      post session_url, params: { email_address: "david@37signals.com", password: "secret123456" }
    end

    assert_response :unauthorized
    assert_nil parsed_cookies.signed[:session_token]
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

  test "destroy closes the signed-out user's live connections" do
    sign_in :david

    remote_connections = mock
    remote_connections.expects(:disconnect).with(reconnect: true)
    ActionCable.server.stubs(:remote_connections).returns(mock.tap { |m| m.expects(:where).with(current_user: users(:david)).returns(remote_connections) })

    delete session_url

    assert_redirected_to root_url
  end

  test "destroy still signs out when the realtime service is unreachable" do
    sign_in :david
    session = users(:david).sessions.last
    ActionCable.server.stubs(:remote_connections).raises(RuntimeError.new("cable down"))

    delete session_url

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

  private
    def with_backlit_sso_enabled
      previous = {
        "OIDC_PROVIDERS" => ENV["OIDC_PROVIDERS"],
        "OIDC_BACKLIT_ISSUER" => ENV["OIDC_BACKLIT_ISSUER"],
        "OIDC_BACKLIT_CLIENT_ID" => ENV["OIDC_BACKLIT_CLIENT_ID"],
        "OIDC_BACKLIT_CLIENT_SECRET" => ENV["OIDC_BACKLIT_CLIENT_SECRET"],
        "OIDC_BACKLIT_REDIRECT_URI" => ENV["OIDC_BACKLIT_REDIRECT_URI"],
        "OIDC_BACKLIT_PROVIDER_NAME" => ENV["OIDC_BACKLIT_PROVIDER_NAME"]
      }

      ENV["OIDC_PROVIDERS"] = "backlit"
      ENV["OIDC_BACKLIT_ISSUER"] = "https://bck.lt"
      ENV["OIDC_BACKLIT_CLIENT_ID"] = "campfire"
      ENV["OIDC_BACKLIT_CLIENT_SECRET"] = "secret"
      ENV["OIDC_BACKLIT_REDIRECT_URI"] = "https://campfire.bck.lt/auth/backlit/callback"
      ENV["OIDC_BACKLIT_PROVIDER_NAME"] = "Backlit"

      yield
    ensure
      previous.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end
end
