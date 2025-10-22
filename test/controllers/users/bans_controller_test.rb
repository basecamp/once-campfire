require "test_helper"

class Accounts::BansControllerTest < ActionDispatch::IntegrationTest
  test "Admin can unban user" do
    sign_in :david

    banned = users(:bruce_banned)
    assert banned.banned?

    patch user_bans_path(banned.id)

    assert_redirected_to edit_account_url
    assert_not banned.reload.banned?
  end

  test "Admin can ban user" do
    sign_in :david

    user = users(:jz)
    assert_not user.banned?

    patch user_bans_path(user.id)

    assert_redirected_to edit_account_url
    assert user.reload.banned?
  end

  test "Admin can't ban admin" do
    sign_in :david

    another_admin = users(:jason)
    patch user_bans_path(another_admin.id)

    assert_redirected_to edit_account_url
    assert_not another_admin.reload.banned?
  end
end
