require "test_helper"

class SsoAuthenticationTest < ActiveSupport::TestCase
  include SsoTestHelper

  setup do
    @auth = OmniAuth::AuthHash.new(
      provider: "oidc",
      uid: "unique-idp-id-123",
      info: OmniAuth::AuthHash::InfoHash.new(
        email: "newuser@example.com",
        name: "New User"
      )
    )
  end

  test "finds existing user by SSO identity" do
    user = users(:jz)
    user.update!(sso_provider: "oidc", sso_uid: "unique-idp-id-123")

    @auth.info.email = user.email_address

    result = SsoAuthentication.find_or_create_user_from(@auth)
    assert_equal user, result
  end

  test "links existing user by email on first SSO login" do
    user = users(:jz)
    @auth.info.email = user.email_address

    assert_nil user.sso_provider

    result = SsoAuthentication.find_or_create_user_from(@auth)

    assert_equal user, result
    assert_equal "oidc", result.reload.sso_provider
    assert_equal "unique-idp-id-123", result.sso_uid
  end

  test "auto-creates new user when no match found" do
    assert_difference -> { User.count }, +1 do
      user = SsoAuthentication.find_or_create_user_from(@auth)

      assert_equal "New User", user.name
      assert_equal "newuser@example.com", user.email_address
      assert_equal "oidc", user.sso_provider
      assert_equal "unique-idp-id-123", user.sso_uid
      assert user.member?
      assert user.active?
    end
  end

  test "auto-created user has no password" do
    user = SsoAuthentication.find_or_create_user_from(@auth)
    assert_nil user.password_digest
  end

  test "auto-created user gets membership to open rooms" do
    user = SsoAuthentication.find_or_create_user_from(@auth)
    assert user.rooms.any?
  end

  test "falls back to email prefix when name is blank" do
    auth = OmniAuth::AuthHash.new(
      provider: "oidc",
      uid: "unique-idp-id-456",
      info: { email: "newuser@example.com" }
    )

    user = SsoAuthentication.find_or_create_user_from(auth)
    assert_equal "newuser", user.name
  end

  test "raises error when email is missing" do
    @auth.info.email = nil

    assert_raises SsoAuthentication::Error, "No email provided by identity provider" do
      SsoAuthentication.find_or_create_user_from(@auth)
    end
  end

  test "raises error when UID is missing" do
    @auth.uid = ""

    assert_raises SsoAuthentication::Error, "No UID provided by identity provider" do
      SsoAuthentication.find_or_create_user_from(@auth)
    end
  end

  test "normalizes email to lowercase" do
    user = users(:jz)
    user.update!(email_address: "JZ@37signals.com")
    @auth.info.email = user.email_address.downcase

    result = SsoAuthentication.find_or_create_user_from(@auth)
    assert_equal user, result
  end

  test "rejects linking when the identity provider marks email as unverified" do
    user = users(:jz)
    @auth.info.email = user.email_address
    @auth.extra = OmniAuth::AuthHash.new(raw_info: { "email_verified" => false })

    assert_raises SsoAuthentication::Error, "Identity provider did not verify the email address" do
      SsoAuthentication.find_or_create_user_from(@auth)
    end
  end

  test "rejects linking by email when the existing account is already SSO-linked" do
    user = users(:sso_user)
    @auth.info.email = user.email_address

    assert_raises SsoAuthentication::Error, "Email is already linked to another SSO account" do
      SsoAuthentication.find_or_create_user_from(@auth)
    end
  end

  test "uses uid as email fallback when uid is an email address" do
    @auth.provider = "oidc"
    @auth.uid = "uid-email@example.com"
    @auth.info.email = nil

    user = SsoAuthentication.find_or_create_user_from(@auth)
    assert_equal "uid-email@example.com", user.email_address
  end

  test "uses raw_info mail attribute as email fallback" do
    @auth.provider = "oidc"
    @auth.info.email = nil
    @auth.extra = OmniAuth::AuthHash.new(raw_info: { "mail" => "raw-mail@example.com" })

    user = SsoAuthentication.find_or_create_user_from(@auth)
    assert_equal "raw-mail@example.com", user.email_address
  end
end
