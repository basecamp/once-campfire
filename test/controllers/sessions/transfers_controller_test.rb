require "test_helper"

class Sessions::TransfersControllerTest < ActionDispatch::IntegrationTest
  test "show renders when not signed in" do
    get session_transfer_url

    assert_response :success
    assert_select "form[action='#{session_transfer_intent_path}']"
  end

  test "update establishes a session when the code is valid" do
    user = users(:david)
    exchange_transfer user.transfer_id

    put session_transfer_url

    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]
    assert_equal "transfer", Session.find_by!(token: parsed_cookies.signed[:session_token]).authentication_method
  end

  test "update is disabled when OIDC is required" do
    configure_oidc("OIDC_MODE" => "required")
    Oidc::Activation.stubs(:ready?).returns(true)
    host! Oidc.configuration.redirect_host
    https!

    put session_transfer_path

    assert_response :forbidden
    assert_nil parsed_cookies.signed[:session_token]
  end

  test "show explains that transfer is disabled when OIDC is required" do
    configure_oidc("OIDC_MODE" => "required")
    Oidc::Activation.stubs(:ready?).returns(true)
    host! Oidc.configuration.redirect_host
    https!

    get session_transfer_path

    assert_redirected_to new_session_url
    assert_equal "Session transfer is unavailable while single sign-on is required.", flash[:alert]
  end

  test "a transfer grant is exchanged once and redirects without the credential" do
    grant = users(:david).transfer_id

    post session_transfer_intent_url, params: { token: grant }

    assert_redirected_to session_transfer_url
    assert_not_includes response.location, grant

    other_browser = open_session
    other_browser.post session_transfer_intent_url, params: { token: grant }
    assert_redirected_to session_transfer_url
    assert_equal "That session transfer link is invalid or has already been used.", other_browser.flash[:alert]
  end

  test "a browser-bound transfer intent cannot be used by another browser" do
    exchange_transfer users(:david).transfer_id

    other_browser = open_session
    other_browser.put session_transfer_url

    assert_equal 400, other_browser.response.status
    assert_nil other_browser.cookies[:session_token]
  end

  test "a consumed browser transfer intent cannot be replayed" do
    exchange_transfer users(:david).transfer_id

    put session_transfer_url
    delete session_url
    put session_transfer_url

    assert_response :bad_request
  end

  private
    def exchange_transfer(grant)
      post session_transfer_intent_url, params: { token: grant }
      assert_redirected_to session_transfer_url
    end
end
