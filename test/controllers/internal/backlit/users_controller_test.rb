require "test_helper"

class Internal::Backlit::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @token = "test-provisioning-token"
    ENV["BACKLIT_PROVISIONING_TOKEN"] = @token
    @headers = {
      "Authorization" => "Bearer #{@token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json"
    }
  end

  teardown do
    ENV.delete("BACKLIT_PROVISIONING_TOKEN")
  end

  test "creates a new SSO user" do
    assert_difference -> { User.count }, +1 do
      post internal_backlit_users_url, params: {
        sub: "1001",
        email: "new@example.com",
        name: "New Person",
        admin: false
      }.to_json, headers: @headers
    end

    assert_response :created
    user = User.find_by!(sso_provider: "backlit", sso_uid: "1001")
    assert_equal "new@example.com", user.email_address
    assert user.member?
  end

  test "claims an existing local user by email instead of duplicating" do
    existing = User.create!(
      name: "Legacy Megan",
      email_address: "legacy@example.com",
      password: "secret123456"
    )

    assert_no_difference -> { User.count } do
      post internal_backlit_users_url, params: {
        sub: "9188",
        email: "legacy@example.com",
        name: "Megan",
        admin: true
      }.to_json, headers: @headers
    end

    assert_response :created
    existing.reload
    assert_equal "backlit", existing.sso_provider
    assert_equal "9188", existing.sso_uid
    assert_equal "Megan", existing.name
    assert existing.administrator?
  end

  test "updates an existing backlit SSO user by sub" do
    user = User.create!(
      name: "Old Name",
      email_address: "old@example.com",
      sso_provider: "backlit",
      sso_uid: "55"
    )

    assert_no_difference -> { User.count } do
      post internal_backlit_users_url, params: {
        sub: "55",
        email: "new-email@example.com",
        name: "New Name",
        admin: false
      }.to_json, headers: @headers
    end

    assert_response :created
    user.reload
    assert_equal "new-email@example.com", user.email_address
    assert_equal "New Name", user.name
  end
end
