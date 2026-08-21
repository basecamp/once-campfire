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

  test "update is disabled whenever OIDC is enabled" do
    configure_oidc
    host! Oidc.configuration.redirect_host
    https!

    put session_transfer_path

    assert_response :forbidden
    assert_nil parsed_cookies.signed[:session_token]
  end

  test "show explains that transfer is disabled whenever OIDC is enabled" do
    configure_oidc
    host! Oidc.configuration.redirect_host
    https!

    get session_transfer_path

    assert_redirected_to new_session_url
    assert_equal "Session transfer is unavailable while single sign-on is enabled.", flash[:alert]
  end

  test "a transfer grant cannot be exchanged after OIDC is enabled" do
    grant = users(:david).transfer_id
    configure_oidc
    host! Oidc.configuration.redirect_host
    https!

    post session_transfer_intent_path, params: { token: grant }

    assert_response :forbidden
    assert CredentialIntent.where(user: users(:david), purpose: "transfer_grant").exists?
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

  test "a transfer cannot replace a different signed-in account" do
    sign_in :david
    original_token = parsed_cookies.signed[:session_token]
    exchange_transfer users(:jason).transfer_id

    assert_no_difference -> { Session.where(user: users(:jason), authentication_method: "transfer").count } do
      put session_transfer_url
    end

    assert_redirected_to root_url
    assert_equal "Sign out before transferring a different account to this browser.", flash[:alert]
    assert_equal original_token, parsed_cookies.signed[:session_token]
    assert Session.exists?(token: original_token)
    assert_equal 1, CredentialIntent.where(user: users(:jason), purpose: "transfer").count

    delete session_url
    assert_redirected_to session_transfer_url
    put session_transfer_url
    assert_redirected_to root_url
    assert_equal users(:jason), Session.find_by!(token: parsed_cookies.signed[:session_token]).user
  end

  test "a session creation failure preserves the browser transfer for retry" do
    exchange_transfer users(:david).transfer_id
    Session.stubs(:start!).raises(ActiveRecord::RecordInvalid.new(Session.new))

    put session_transfer_url

    assert_response :service_unavailable
    assert_nil parsed_cookies.signed[:session_token]

    Session.unstub(:start!)
    put session_transfer_url

    assert_redirected_to root_url
    assert_equal "transfer", Session.find_by!(token: parsed_cookies.signed[:session_token]).authentication_method
  end

  private
    def exchange_transfer(grant)
      post session_transfer_intent_url, params: { token: grant }
      assert_redirected_to session_transfer_url
    end
end
