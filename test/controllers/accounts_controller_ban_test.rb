require "test_helper"

class BanEditingTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :banner
  end

  test "banned_user_get_forbidden_access" do
    assert users(:banner).member?
    assert users(:banner).banned?

    get edit_account_url
    # if you are banned, you cannot get there
    assert_response :forbidden
  end

  # Generated with ChatGPT
  test "admin can unban banner user" do
    sign_in :david

    banner = users(:banner)
    assert banner.banned?, "Banner should start banned for this test"

    patch account_user_path(banner), params: { user: { role: "member", banned: "0" } }

    assert_redirected_to edit_account_url
    assert_not banner.reload.banned?, "Banner should be unbanned after admin update"
  end
end
