require "test_helper"

class Oidc::SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    configure_oidc
    host! Oidc.configuration.redirect_host
    https!
  end

  test "creates a federated Campfire session" do
    Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "jz-controller-subject")
    auth = oidc_auth(
      subject: "jz-controller-subject", email: users(:jz).email_address,
      claims: { "sid" => "controller-provider-session" }
    )
    flow = consumed_flow

    assert_difference -> { Session.count }, +1 do
      get "/auth/openid_connect/callback", env: { "omniauth.auth" => auth, "oidc.flow" => flow }
    end

    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]

    session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    assert_equal users(:jz), session.user
    assert_equal "jz-controller-subject", session.identity.subject
    assert_equal "controller-provider-session", session.oidc_session_id
    assert session.expires_at.future?
    assert_not Oidc::Flow.exists?(flow.id)
  end

  test "required-mode verification lands on an explicit pre-activation success state" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "required-verification-subject")
    Oidc::Activation.stubs(:ready?).returns(false)

    get "/auth/openid_connect/callback", env: {
      "omniauth.auth" => oidc_auth(
        subject: "required-verification-subject", email: users(:jz).email_address
      )
    }

    assert_redirected_to new_session_url
    follow_redirect!
    assert_response :success
    assert_select "main h1", text: "Sign in to #{accounts(:signal).name}"
    assert_select "[role='status']", text: /verification is complete/
  end

  test "preserves the originally requested URL" do
    Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "oidc-subject")
    get room_url(rooms(:watercooler))
    assert_redirected_to new_session_url

    get "/auth/openid_connect/callback", env: {
      "omniauth.auth" => oidc_auth(email: users(:jz).email_address)
    }

    assert_redirected_to room_url(rooms(:watercooler))
  end

  test "returns a generic failure for invalid identity claims" do
    get "/auth/openid_connect/callback", env: {
      "omniauth.auth" => oidc_auth(email: users(:jz).email_address, claims: { "email_verified" => false })
    }

    assert_redirected_to new_session_url
    assert_equal "Single sign-on could not be completed. Please try again or contact an administrator.", flash[:alert]
  end

  test "handles middleware failures without exposing provider details" do
    get "/auth/failure", env: { "omniauth.error" => RuntimeError.new("provider secret") }

    assert_redirected_to new_session_url
    assert_not_includes flash[:alert], "provider secret"
  end

  test "rollback preparation durably blocks new authentication mutations" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "blocked-subject")
    accounts(:signal).update!(oidc_transition_state: "rollback_prepared")

    assert_no_difference -> { Session.count } do
      get "/auth/openid_connect/callback", env: {
        "omniauth.auth" => oidc_auth(subject: identity.subject, email: users(:jz).email_address)
      }
    end

    assert_response :service_unavailable
    assert_nil accounts(:signal).reload.oidc_verified_at
  end

  test "cancellation prevents every callback mutation" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "canceled-subject")
    sign_in :jz
    existing_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    subscription = push_subscriptions(:jz_chrome)
    subscription.update_column(:session_id, existing_session.id)
    flow = consumed_flow(initiating_session_id: existing_session.id)
    Oidc::Flow.cancel!(@browser_token)
    Identity.expects(:authenticate).never
    Oidc::Activation.expects(:record_successful_authentication!).never

    assert_no_changes -> { [ Session.count, subscription.reload.session_id, identity.reload.verified_at ] } do
      get "/auth/openid_connect/callback", env: {
        "omniauth.auth" => oidc_auth(subject: identity.subject, email: users(:jz).email_address),
        "oidc.flow" => flow
      }
    end

    assert_redirected_to new_session_url
    assert Session.exists?(existing_session.id)
    assert_nil accounts(:signal).reload.oidc_verified_at
  end

  private
    def consumed_flow(initiating_session_id: nil)
      @browser_token = SecureRandom.urlsafe_base64(32)
      Oidc::Flow.start!(
        state: "controller-state",
        nonce: "nonce",
        pkce_verifier: "verifier",
        browser_token: @browser_token,
        initiating_session_id:,
        linking_intent: nil
      )
      Oidc::Flow.consume!(state: "controller-state", browser_token: @browser_token)
    end
end
