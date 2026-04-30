require "test_helper"

class Users::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show" do
    get user_profile_url

    assert_response :success
    assert_select "form[data-controller='sessions'][data-turbo='false']"
  end

  test "update" do
    put user_profile_url, params: { user: { name: "John Doe", bio: "Acrobat" } }

    assert_redirected_to user_profile_url
    assert_equal "John Doe", users(:david).reload.name
    assert_equal "Acrobat", users(:david).bio
    assert_equal "david@37signals.com", users(:david).email_address
  end

  test "updates are limited to the current user" do
    put user_profile_url(users(:jason)), params: { user: { name: "John Doe" } }

    assert_equal "Jason", users(:jason).reload.name
  end

  test "show disables name and email fields for SSO users" do
    sso_user = users(:sso_user)
    sso_user.update!(password: "secret123456")
    sign_in sso_user

    get user_profile_url

    assert_select "input[name='user[name]'][disabled]"
    assert_select "input[name='user[email_address]'][disabled]"
  end

  test "show keeps password field for non-SSO users when password registration is disabled" do
    with_env("DISABLE_PASSWORD_REGISTRATION" => "true") do
      get user_profile_url
      assert_select "input[name='user[password]']"
    end
  end

  test "update ignores SSO name and email changes" do
    sso_user = users(:sso_user)
    sso_user.update!(password: "secret123456")
    sign_in sso_user

    put user_profile_url, params: { user: { name: "Renamed", email_address: "renamed@example.com", bio: "Updated bio" } }

    assert_redirected_to user_profile_url
    assert_equal "SSO User", sso_user.reload.name
    assert_equal "sso@example.com", sso_user.email_address
    assert_equal "Updated bio", sso_user.bio
  end
end
