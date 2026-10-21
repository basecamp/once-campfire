require "test_helper"

class Users::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show" do
    get user_profile_url

    assert_response :success
  end

  test "show includes install instructions for Edge" do
    get user_profile_url, headers: { "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 Edge/18.18363" }

    assert_response :success
    assert_select ".pwa__instructions img[src*='install-edge']"
  end

  test "update" do
    put user_profile_url, params: { user: { name: "John Doe", bio: "Acrobat" } }

    assert_redirected_to user_profile_url
    assert_equal "John Doe", users(:david).reload.name
    assert_equal "Acrobat", users(:david).bio
    assert_equal "david@37signals.com", users(:david).email_address
  end

  test "changing the password signs out the account's other devices but not this browser" do
    other_device = open_session
    other_device.post session_url, params: { email_address: users(:david).email_address, password: "secret123456" }
    other_device.get user_profile_url
    other_device.assert_response :success

    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456" } }
    assert_redirected_to user_profile_url

    other_device.get user_profile_url
    other_device.assert_redirected_to new_session_url
    get user_profile_url
    assert_response :success
    assert_equal 1, users(:david).sessions.count
  end

  test "changing the password signs this browser out when it changes again before its new session starts" do
    User.stubs(:uncached).returns(BCrypt::Password.create("someone else's secret", cost: BCrypt::Engine::MIN_COST))

    assert_changes -> { users(:david).sessions.count }, to: 0 do
      put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456" } }
    end

    assert_redirected_to new_session_url
  end

  test "changing the password gives this browser a new session, so a copy of its cookie stops working" do
    copied_cookie = cookies[:session_token]

    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456" } }
    assert_not_equal copied_cookie, cookies[:session_token]

    copy = open_session
    copy.cookies[:session_token] = copied_cookie
    copy.get user_profile_url
    copy.assert_redirected_to new_session_url
  end

  test "changing the password along with the avatar still signs this browser back in and closes live connections" do
    remote_connections = mock
    remote_connections.expects(:disconnect).with(reconnect: true)
    ActionCable.server.stubs(:remote_connections).returns(mock.tap { |m| m.expects(:where).with(current_user: users(:david)).returns(remote_connections) })

    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456", avatar: fixture_file_upload("moon.jpg", "image/jpeg") } }
    assert_redirected_to user_profile_url
    assert users(:david).reload.avatar.attached?

    get user_profile_url
    assert_response :success
  end

  test "changing the password closes the account's live connections" do
    remote_connections = mock
    remote_connections.expects(:disconnect).with(reconnect: true)
    ActionCable.server.stubs(:remote_connections).returns(mock.tap { |m| m.expects(:where).with(current_user: users(:david)).returns(remote_connections) })

    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456" } }

    assert_redirected_to user_profile_url
  end

  test "changing the password still signs out other sessions when the realtime service is unreachable" do
    other_session = users(:david).sessions.first
    ActionCable.server.stubs(:remote_connections).raises(RuntimeError.new("cable down"))

    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456" } }

    assert_redirected_to user_profile_url
    assert_not Session.exists?(other_session.id)
  end

  test "updating the profile without a new password leaves other sessions signed in" do
    ActionCable.server.expects(:remote_connections).never

    assert_no_difference -> { users(:david).sessions.count } do
      put user_profile_url, params: { user: { name: "David", password: "" } }
    end

    assert_redirected_to user_profile_url
  end

  test "changing the password with the current one" do
    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456" } }

    assert_redirected_to user_profile_url
    assert_equal "✓", flash[:notice]
    assert users(:david).reload.authenticate("a new secret123456")
  end

  test "changing the password without the current one changes nothing" do
    assert_password_change_refused "Enter your current password to change it.",
      user: { name: "Someone else", password: "a new secret123456" }
  end

  test "changing the password with a wrong current one changes nothing" do
    assert_password_change_refused "That isn't your current password.",
      user: { name: "Someone else", password: "a new secret123456", password_challenge: "not my password" }
  end

  test "a new password needs the current one however the form spells it" do
    assert_password_change_refused "Enter your current password to change it.",
      user: { name: "Someone else", "password(1)" => "a new secret123456" }
  end

  test "editing the profile with an empty current password doesn't need it" do
    put user_profile_url, params: { user: { name: "Dave", password: "", password_challenge: "" } }

    assert_redirected_to user_profile_url
    assert_equal "Dave", users(:david).reload.name
  end

  test "editing the profile without changing the password doesn't need the current one" do
    put user_profile_url, params: { user: { name: "Dave", bio: "Acrobat", password: "" } }

    assert_redirected_to user_profile_url
    assert_equal "Dave", users(:david).reload.name
    assert users(:david).authenticate("secret123456")
  end

  test "attempts to change the password are rate limited like signing in" do
    Users::ProfilesController.cache_store.stubs(:increment).returns(11)

    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456" } }
    assert_redirected_to user_profile_url
    assert_equal "Too many attempts. Try again in a few minutes.", flash[:alert]
    assert users(:david).reload.authenticate("secret123456")

    put user_profile_url, params: { user: { password: "a new secret123456" } }
    assert_equal "Enter your current password to change it.", flash[:alert]

    put user_profile_url, params: { user: { name: "Dave" } }
    assert_equal "Dave", users(:david).reload.name
  end

  test "any current password sent counts toward the rate limit, however blank it looks" do
    Users::ProfilesController.cache_store.stubs(:increment).returns(11)

    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: " " } }
    assert_equal "Too many attempts. Try again in a few minutes.", flash[:alert]
  end

  test "a current password that isn't text is no current password" do
    [ false, [], {}, 0 ].each do |challenge|
      put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: challenge } }, as: :json

      assert_redirected_to user_profile_url
      assert_equal "Enter your current password to change it.", flash[:alert]
      assert users(:david).reload.authenticate("secret123456")
    end
  end

  test "changing the password removes the other devices' push subscriptions, and this browser can register its own again" do
    stub_web_push_dns_resolution
    endpoint = push_subscriptions(:david_chrome).attributes.slice("endpoint", "p256dh_key", "auth_key")

    put user_profile_url, params: { user: { password: "a new secret123456", password_challenge: "secret123456" } }
    assert_empty users(:david).push_subscriptions

    post user_push_subscriptions_url, params: { push_subscription: endpoint }
    assert_response :ok
    assert_equal [ endpoint["endpoint"] ], users(:david).push_subscriptions.pluck(:endpoint)
  end

  test "updates are limited to the current user" do
    put user_profile_url(users(:jason)), params: { user: { name: "John Doe" } }

    assert_equal "Jason", users(:jason).reload.name
  end

  private
    def assert_password_change_refused(alert, params)
      other_device = open_session
      other_device.post session_url, params: { email_address: users(:david).email_address, password: "secret123456" }
      ActionCable.server.expects(:remote_connections).never

      assert_no_changes -> { [ Session.count, Push::Subscription.count ] } do
        put user_profile_url, params: params
      end

      assert_redirected_to user_profile_url
      assert_equal alert, flash[:alert]
      assert users(:david).reload.authenticate("secret123456")
      assert_equal "David", users(:david).name
      other_device.get user_profile_url
      other_device.assert_response :success
    end
end
