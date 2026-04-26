require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @join_code = accounts(:signal).join_code
  end

  test "show" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "false") do
      sign_in :david
      get user_url(users(:david))
      assert_response :ok
    end
  end

  test "new" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "false") do
      get join_url(@join_code)
      assert_response :success
    end
  end

  test "new does not allow a signed in user" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "false") do
      sign_in :david

      get join_url(@join_code)
      assert_redirected_to root_url
    end
  end

  test "new requires a join code" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "false") do
      get join_url("not")
      assert_response :not_found
    end
  end

  test "create" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "false") do
      assert_difference -> { User.count }, 1 do
        post join_url(@join_code), params: { user: { name: "New Person", email_address: "new@37signals.com", password: "secret123456" } }
      end

      assert_redirected_to root_url

      user = User.last
      assert_equal user.id, Session.find_by(token: parsed_cookies.signed[:session_token]).user.id
      assert_equal Rooms::Open.all, user.rooms
    end
  end

  test "new redirects to login when password registration is disabled" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "true") do
      get join_url(@join_code)
      assert_redirected_to new_session_url
    end
  end

  test "create redirects to login when password registration is disabled" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "true") do
      assert_no_difference -> { User.count } do
        post join_url(@join_code), params: { user: { name: "New Person", email_address: "new@37signals.com", password: "secret123456" } }
      end
      assert_redirected_to new_session_url
    end
  end

  test "creating a new user with an existing email address will redirect to login screen" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "false") do
      assert_no_difference -> { User.count } do
        post join_url(@join_code), params: { user: { name: "Another David", email_address: users(:david).email_address, password: "secret123456" } }
      end

      assert_redirected_to new_session_url(email_address: users(:david).email_address)
    end
  end

  test "password registration toggle treats uppercase true as disabled" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "TRUE") do
      get join_url(@join_code)
      assert_redirected_to new_session_url
    end
  end
end
