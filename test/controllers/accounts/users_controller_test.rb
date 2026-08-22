require "test_helper"

class Accounts::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "update" do
    assert users(:david).administrator?

    put account_user_url(users(:david)), params: { user: { role: "administrator" } }

    assert_redirected_to edit_account_url
    assert users(:david).reload.administrator?
  end

  test "destroy" do
    assert_difference -> { User.active.count }, -1 do
      delete account_user_url(users(:david))
    end

    assert_redirected_to edit_account_url
    assert_nil User.active.find_by(id: users(:david).id)
  end

  test "the last active administrator cannot be demoted" do
    User.active.where(role: :administrator).where.not(id: users(:david).id).update_all(role: :member)

    put account_user_url(users(:david)), params: { user: { role: "member" } }

    assert_response :forbidden
    assert users(:david).reload.administrator?
    assert users(:david).active?
  end

  test "the last active administrator cannot be deactivated" do
    User.active.where(role: :administrator).where.not(id: users(:david).id).update_all(role: :member)

    delete account_user_url(users(:david))

    assert_response :forbidden
    assert users(:david).reload.administrator?
    assert users(:david).active?
  end

  test "a JIT-provisioned user needs a local recovery password before promotion" do
    user = users(:kevin)
    identity = Identity.create!(
      user:, issuer: "https://jit.example.test", subject: "jit-administrator-candidate",
      provider_fingerprint: Digest::SHA256.hexdigest("jit-provider"), provisioned: true
    )

    put account_user_url(user), params: { user: { role: "administrator" } }

    assert_response :forbidden
    assert user.reload.member?
    assert identity.reload.provisioned?
  end

  test "resetting a JIT user's password permits later administrator promotion" do
    user = users(:kevin)
    identity = Identity.create!(
      user:, issuer: "https://jit.example.test", subject: "recovered-administrator-candidate",
      provider_fingerprint: Digest::SHA256.hexdigest("jit-provider"), provisioned: true
    )
    user.update!(password: "new-local-recovery-password")

    put account_user_url(user), params: { user: { role: "administrator" } }

    assert_redirected_to edit_account_url
    assert user.reload.administrator?
    assert_not identity.reload.provisioned?
  end

  test "non-admins cannot perform actions" do
    sign_in :kevin

    put account_user_url(users(:david)), params: { user: { role: "administrator" } }
    assert_response :forbidden

    delete account_user_url(users(:david))
    assert_response :forbidden
  end
end
