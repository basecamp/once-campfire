require "test_helper"

class Accounts::CustomStylesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show serves custom styles as plain CSS" do
    accounts(:signal).update! custom_styles: ":root { --color-text: red; }"

    get account_custom_styles_url
    assert_response :ok
    assert_equal "text/css", @response.media_type
    assert_equal ":root { --color-text: red; }", @response.body
  end

  test "show is accessible without authentication" do
    accounts(:signal).update! custom_styles: ":root { --color-text: red; }"
    reset!

    get account_custom_styles_url
    assert_response :ok
    assert_equal "text/css", @response.media_type
  end

  test "show serves markup verbatim as inert CSS text, never HTML" do
    payload = "</style><script>alert(1)</script>"
    accounts(:signal).update! custom_styles: payload

    get account_custom_styles_url
    assert_response :ok
    assert_equal "text/css", @response.media_type
    assert_equal payload, @response.body
  end

  test "edit" do
    get edit_account_custom_styles_url
    assert_response :ok
  end

  test "update" do
    assert users(:david).administrator?

    put account_custom_styles_url, params: { account: { custom_styles: ":root { --color-text: red; }" } }

    assert_redirected_to edit_account_custom_styles_url
    assert_equal accounts(:signal).custom_styles, ":root { --color-text: red; }"
  end

  test "non-admins cannot update" do
    sign_in :kevin
    assert users(:kevin).member?

    put account_custom_styles_url, params: { account: { custom_styles: ":root { --color-text: red; }" } }
    assert_response :forbidden
  end
end
