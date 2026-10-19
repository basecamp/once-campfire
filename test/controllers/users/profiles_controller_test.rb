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

    put user_profile_url, params: { user: { password: "a new secret123456" } }
    assert_redirected_to user_profile_url

    other_device.get user_profile_url
    other_device.assert_redirected_to new_session_url
    get user_profile_url
    assert_response :success
    assert_equal 1, users(:david).sessions.count
  end

  test "changing the password gives this browser a new session, so a copy of its cookie stops working" do
    copied_cookie = cookies[:session_token]

    put user_profile_url, params: { user: { password: "a new secret123456" } }
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

    put user_profile_url, params: { user: { password: "a new secret123456", avatar: fixture_file_upload("moon.jpg", "image/jpeg") } }
    assert_redirected_to user_profile_url
    assert users(:david).reload.avatar.attached?

    get user_profile_url
    assert_response :success
  end

  test "changing the password closes the account's live connections" do
    remote_connections = mock
    remote_connections.expects(:disconnect).with(reconnect: true)
    ActionCable.server.stubs(:remote_connections).returns(mock.tap { |m| m.expects(:where).with(current_user: users(:david)).returns(remote_connections) })

    put user_profile_url, params: { user: { password: "a new secret123456" } }

    assert_redirected_to user_profile_url
  end

  test "changing the password still signs out other sessions when the realtime service is unreachable" do
    other_session = users(:david).sessions.first
    ActionCable.server.stubs(:remote_connections).raises(RuntimeError.new("cable down"))

    put user_profile_url, params: { user: { password: "a new secret123456" } }

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

  test "updates are limited to the current user" do
    put user_profile_url(users(:jason)), params: { user: { name: "John Doe" } }

    assert_equal "Jason", users(:jason).reload.name
  end
end
