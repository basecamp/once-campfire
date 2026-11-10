require "test_helper"

class User::SsoPasswordTest < ActiveSupport::TestCase
  test "SSO users cannot change their password" do
    user = users(:sso_user)

    assert_not user.update(password: "a new secret123456", password_challenge: "secret123456")
    assert_includes user.errors[:password], "is managed in Backlit"
    assert user.reload.authenticate("secret123456")
  end

  test "non-SSO users can still change their password" do
    user = users(:david)

    assert user.update(password: "a new secret123456", password_challenge: "secret123456")
    assert user.reload.authenticate("a new secret123456")
  end
end
