require "test_helper"

class Sessions::PasswordResetsControllerTest < ActionDispatch::IntegrationTest
  include ApplicationHelper

  test "password reset" do
    user = users(:kevin)
    password_reset_id =  user.password_reset_id
    new_password = "new_password"
    confirm_new_password = "new_password"
    old_password = user.password_digest

    patch session_password_reset_path(user), params: { user: {
      new_password: new_password,
      confirm_new_password: confirm_new_password,
      password_reset_id: password_reset_id
    } }

    user.reload
    new_password = user.password_digest

      assert_equal old_password, new_password
  end

  test "send password reset mail" do
    user = users(:kevin)

    if smtp_enabled?
      assert_emails 1 do
        post session_password_resets_path, params: { email_address: user.email_address }
      end
    else
      assert_emails 0 do
        post session_password_resets_path, params: { email_address: user.email_address }
      end
    end
  end
end
