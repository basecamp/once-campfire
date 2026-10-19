require "test_helper"

class Sessions::TransfersControllerTest < ActionDispatch::IntegrationTest
  test "show renders when not signed in" do
    get session_transfer_url("some-token")

    assert_response :success
    assert_select "form[data-controller='auto-submit']", count: 1
    assert_select "input[name='_method'][value='put']", count: 1
    assert_equal response.body.scan(/<form\b/).size, response.body.scan("</form>").size
    assert_match(/<form\b[^>]*data-controller="auto-submit"[^>]*>(?:\s*<input\b[^>]*>)*\s*<\/form>/, response.body)
  end

  test "update establishes a session when the code is valid" do
    user = users(:david)

    put session_transfer_url(user.transfer_id)

    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]
  end

  test "update rejects a link made before the password changed" do
    user = users(:david)
    transfer_id = user.transfer_id
    user.update!(password: "a new secret123456")

    put session_transfer_url(transfer_id)

    assert_response :bad_request
    assert_nil parsed_cookies.signed[:session_token]
  end
end
