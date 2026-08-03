require "test_helper"

class Oidc::FlowsControllerTest < ActionController::TestCase
  setup do
    configure_oidc
    @request.host = Oidc.configuration.redirect_host
    @request.env["HTTPS"] = "on"
  end

  test "canceling a flow clears every browser-held OIDC secret" do
    browser_token = SecureRandom.urlsafe_base64(32)
    cookies[Oidc::BROWSER_COOKIE] = browser_token
    Oidc::Flow.start!(
      state: "oauth-state", nonce: "nonce", pkce_verifier: "verifier",
      browser_token:, initiating_session_id: nil, linking_intent: nil
    )
    session[Oidc::FLOW_STARTED_AT_SESSION_KEY] = Time.current.to_i
    session[Oidc::LINKING_INTENT_SESSION_KEY] = { "state" => "linking-state" }
    session["omniauth.state"] = "oauth-state"
    session["omniauth.nonce"] = "nonce"
    session["omniauth.pkce.verifier"] = "verifier"

    delete :destroy

    assert_redirected_to new_session_url(oidc_retry: 1)
    assert_not Oidc.flow_in_progress?(session)
    assert_nil session[Oidc::LINKING_INTENT_SESSION_KEY]
    assert_nil session["omniauth.state"]
    assert_nil session["omniauth.nonce"]
    assert_nil session["omniauth.pkce.verifier"]
    assert_not Oidc::Flow.pending_for?(browser_token)
  end

  test "canceling processing invalidates callback finalization" do
    browser_token = SecureRandom.urlsafe_base64(32)
    cookies[Oidc::BROWSER_COOKIE] = browser_token
    Oidc::Flow.start!(
      state: "oauth-state", nonce: "nonce", pkce_verifier: "verifier",
      browser_token:, initiating_session_id: nil, linking_intent: nil
    )
    consumed = Oidc::Flow.consume!(state: "oauth-state", browser_token:)

    delete :destroy

    assert_redirected_to new_session_url(oidc_retry: 1)
    assert_raises(Oidc::Flow::Invalid) { consumed.finalize! { flunk "canceled callback mutated state" } }
  end

  test "does not claim cancellation after callback completion" do
    browser_token = SecureRandom.urlsafe_base64(32)
    cookies[Oidc::BROWSER_COOKIE] = browser_token
    Oidc::Flow.start!(
      state: "oauth-state", nonce: "nonce", pkce_verifier: "verifier",
      browser_token:, initiating_session_id: nil, linking_intent: nil
    )
    consumed = Oidc::Flow.consume!(state: "oauth-state", browser_token:)
    consumed.finalize! { true }

    delete :destroy

    assert_redirected_to root_url
    assert_equal "No active single sign-on attempt was canceled. It may already have finished.", flash[:alert]
  end
end
