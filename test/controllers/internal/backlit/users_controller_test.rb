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
    assert_equal "New Person", user.name
    assert user.member?
  end

  test "uses the email local-part when name is blank or looks like an email" do
    post internal_backlit_users_url, params: {
      sub: "1002",
      email: "alex@example.com",
      name: ""
    }.to_json, headers: @headers

    assert_response :created
    assert_equal "alex", User.find_by!(sso_uid: "1002").name

    post internal_backlit_users_url, params: {
      sub: "1003",
      email: "sam@example.com",
      name: "sam@example.com"
    }.to_json, headers: @headers

    assert_response :created
    assert_equal "sam", User.find_by!(sso_uid: "1003").name
  end

  test "claims an existing local user by email instead of duplicating" do
    existing = User.create!(
      name: "Legacy Megan",
      email_address: "legacy@example.com",
      password: "secret123456"
    )
    existing.sessions.create!(user_agent: "Test", ip_address: "127.0.0.1")

    assert_no_difference -> { User.count } do
      post internal_backlit_users_url, params: {
        sub: "9188",
        email: "legacy@example.com",
        name: "Megan"
      }.to_json, headers: @headers
    end

    assert_response :created
    existing.reload
    assert_equal "backlit", existing.sso_provider
    assert_equal "9188", existing.sso_uid
    assert_equal "Megan", existing.name
    assert existing.member?
    assert_nil existing.password_digest
    assert_equal 0, existing.sessions.count
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
        name: "New Name"
      }.to_json, headers: @headers
    end

    assert_response :created
    user.reload
    assert_equal "new-email@example.com", user.email_address
    assert_equal "New Name", user.name
  end

  test "applies admin from Backlit to promote and demote Campfire administrators" do
    existing = User.create!(
      name: "Operator",
      email_address: "operator@example.com",
      sso_provider: "backlit",
      sso_uid: "1",
      role: :administrator
    )

    post internal_backlit_users_url, params: {
      sub: "1",
      email: "operator@example.com",
      name: "Operator",
      admin: false
    }.to_json, headers: @headers

    assert_response :created
    assert existing.reload.member?

    member = User.create!(
      name: "Crew",
      email_address: "crew@example.com",
      sso_provider: "backlit",
      sso_uid: "2",
      role: :member
    )

    post internal_backlit_users_url, params: {
      sub: "2",
      email: "crew@example.com",
      name: "Crew",
      admin: true
    }.to_json, headers: @headers

    assert_response :created
    assert member.reload.administrator?
  end

  test "preserves role when admin is omitted and does not demote bots" do
    admin = User.create!(
      name: "Operator",
      email_address: "keep-admin@example.com",
      sso_provider: "backlit",
      sso_uid: "10",
      role: :administrator
    )

    post internal_backlit_users_url, params: {
      sub: "10",
      email: "keep-admin@example.com",
      name: "Operator"
    }.to_json, headers: @headers

    assert_response :created
    assert admin.reload.administrator?

    bot = User.create!(
      name: "Backlit Sync",
      email_address: "bot@example.com",
      sso_provider: "backlit",
      sso_uid: "11",
      role: :bot
    )

    post internal_backlit_users_url, params: {
      sub: "11",
      email: "bot@example.com",
      name: "Backlit Sync",
      admin: true
    }.to_json, headers: @headers

    assert_response :created
    assert bot.reload.bot?
  end
end
