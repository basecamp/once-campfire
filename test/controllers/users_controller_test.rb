require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @join_code = accounts(:signal).join_code
  end

  test "show" do
    sign_in :david
    get user_url(users(:david))
    assert_response :ok
  end

  test "new" do
    exchange_join_code
    get join_url
    assert_response :success
  end

  test "new does not allow a signed in user" do
    sign_in :david

    get join_url(anchor: "token=#{@join_code}")
    assert_redirected_to root_url
  end

  test "new exchanges the fragment credential before showing signup" do
    get join_url

    assert_response :success
    assert_select "form[action='#{join_intent_path}']"

    post join_intent_url, params: { token: "not" }
    assert_redirected_to join_url
    assert_equal "That invitation link is invalid or has expired.", flash[:alert]
  end

  test "create" do
    exchange_join_code
    assert_difference -> { User.count }, 1 do
      post join_url, params: {
        user: { name: "New Person", email_address: " NEW@37SIGNALS.COM ", password: "secret123456" }
      }
    end

    assert_redirected_to root_url

    user = User.last
    assert_equal "new@37signals.com", user.email_address
    assert_equal user.email_address, user.normalized_email_address
    assert_equal user.id, Session.find_by(token: parsed_cookies.signed[:session_token]).user.id
    assert_equal Rooms::Open.all, user.rooms
  end

  test "creating a new user with an existing email address will redirect to login screen" do
    exchange_join_code
    assert_no_difference -> { User.count } do
      post join_url, params: {
        user: { name: "Another David", email_address: " DAVID@37SIGNALS.COM ", password: "secret123456" }
      }
    end

    assert_redirected_to new_session_url(email_address: users(:david).email_address)
  end

  test "create requires a browser-bound join intent" do
    post join_url, params: {
      user: { name: "No Invite", email_address: "no-invite@example.com", password: "secret123456" }
    }

    assert_response :not_found
    assert_not User.exists?(email_address: "no-invite@example.com")
  end

  test "join credentials stay in the fragment and redirects are token-free" do
    url = URI(join_url(anchor: "token=#{@join_code}"))

    assert_equal "token=#{@join_code}", url.fragment
    assert_not_includes url.request_uri, @join_code

    post join_intent_url, params: { token: @join_code }
    assert_redirected_to join_url
    assert_not_includes response.location, @join_code
  end

  private
    def exchange_join_code
      post join_intent_url, params: { token: @join_code }
      assert_redirected_to join_url
    end
end

class UsersJoinCodeConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test "join-code rotation that commits during staging prevents signup" do
    account = accounts(:signal)
    stale_code = account.join_code
    ready = Queue.new
    release = Queue.new
    result = Queue.new
    StagedUpload.stubs(:stage).with do |*|
      ready << true
      release.pop
      true
    end.returns(nil)

    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.post join_intent_url, params: { token: stale_code }
    assert_equal 302, browser.response.status

    request = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        browser.post join_url, params: { user: {
          name: "Stale Invite", email_address: "stale-invite@example.com",
          password: "secret123456", avatar: fixture_file_upload("moon.jpg", "image/jpeg")
        } }
        result << browser.response.status
      end
    end
    ready.pop
    account.reset_join_code! actor: users(:david)
    release << true
    request.join

    assert_equal 404, result.pop
    assert_not User.exists?(email_address: "stale-invite@example.com")
  ensure
    release << true if request&.alive?
    request&.join(2)
  end
end
