require "test_helper"

class Oidc::LinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    configure_oidc
    host! Oidc.configuration.redirect_host
    https!
    sign_in :jz
  end

  test "links SSO from an authenticated local session" do
    original_session = users(:jz).sessions.order(:id).last
    subscription = push_subscriptions(:jz_chrome)
    subscription.update!(session: original_session)

    reauthenticate_for_first_link
    get oidc_link_url
    assert_response :success
    assert_select "form[action='#{openid_connect_path}']"
    state = css_select("input[name='linking_state']").sole["value"]

    get "/auth/openid_connect/callback", params: { state: state }, env: {
      "omniauth.auth" => oidc_auth(subject: "linked-subject", email: users(:jz).email_address)
    }

    assert_redirected_to user_profile_url
    assert_equal "linked-subject", users(:jz).identities.find_by!(issuer: Oidc.issuer).subject
    assert_not Session.exists?(original_session.id)
    replacement_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    assert_equal "oidc", replacement_session.authentication_method
    assert_equal replacement_session, subscription.reload.session
  end

  test "requires the identity-provider email to match the local account" do
    reauthenticate_for_first_link
    get oidc_link_url
    state = css_select("input[name='linking_state']").sole["value"]

    get "/auth/openid_connect/callback", params: { state: state }, env: {
      "omniauth.auth" => oidc_auth(subject: "wrong-subject", email: users(:kevin).email_address)
    }

    assert_redirected_to user_profile_url
    assert_not users(:jz).identities.exists?
    assert Session.exists?(users(:jz).sessions.order(:id).last.id)
  end

  test "keeps the original session and identity state when replacement session creation fails" do
    original_session = users(:jz).sessions.order(:id).last
    reauthenticate_for_first_link
    get oidc_link_url
    state = css_select("input[name='linking_state']").sole["value"]
    Session.stubs(:start!).raises(ActiveRecord::RecordInvalid.new(Session.new))

    get "/auth/openid_connect/callback", params: { state: state }, env: {
      "omniauth.auth" => oidc_auth(subject: "failed-session-subject", email: users(:jz).email_address)
    }

    assert_redirected_to user_profile_url
    assert Session.exists?(original_session.id)
    assert_not users(:jz).identities.exists?(subject: "failed-session-subject")
  end

  test "provider failure during linking returns to the authenticated profile" do
    original_session = users(:jz).sessions.order(:id).last
    reauthenticate_for_first_link
    get oidc_link_url

    get "/auth/failure", env: { "omniauth.error" => RuntimeError.new("provider unavailable") }

    assert_redirected_to user_profile_url
    assert Session.exists?(original_session.id)
  end

  test "revocation before the callback lock cannot mint a replacement credential" do
    original_session = users(:jz).sessions.order(:id).last
    reauthenticate_for_first_link
    get oidc_link_url
    state = css_select("input[name='linking_state']").sole["value"]
    Oidc::SessionsController.any_instance.expects(:find_session_by_cookie).with(lock: true).returns(nil)

    assert_no_difference -> { Session.count } do
      get "/auth/openid_connect/callback", params: { state: }, env: {
        "omniauth.auth" => oidc_auth(subject: "revoked-link-subject", email: users(:jz).email_address)
      }
    end

    assert_redirected_to user_profile_url
    assert_not users(:jz).identities.exists?(subject: "revoked-link-subject")
  end

  test "replacement failure rolls back identity session and push transfer" do
    original_session = users(:jz).sessions.order(:id).last
    subscription = push_subscriptions(:jz_chrome)
    subscription.update!(session: original_session)
    reauthenticate_for_first_link
    get oidc_link_url
    state = css_select("input[name='linking_state']").sole["value"]
    Session.any_instance.stubs(:destroy!).raises(ActiveRecord::StatementInvalid, "simulated failure")

    assert_no_difference -> { Session.count } do
      get "/auth/openid_connect/callback", params: { state: }, env: {
        "omniauth.auth" => oidc_auth(subject: "rolled-back-subject", email: users(:jz).email_address)
      }
    end

    assert_redirected_to user_profile_url
    assert Session.exists?(original_session.id)
    assert_equal original_session, subscription.reload.session
    assert_not users(:jz).identities.exists?(subject: "rolled-back-subject")
  end

  test "first identity linking prompts for the current password" do
    get oidc_link_url

    assert_response :success
    assert_select "form[action='#{oidc_link_path}']"
    assert_select "input[name='current_password']"
    assert_select "form[action='#{openid_connect_path}']", count: 0
  end

  test "a stolen session cannot swap email attach an attacker subject and restore email" do
    user = users(:jz)
    original_email = user.email_address
    attacker_email = "attacker-controlled@example.com"

    put user_profile_url, params: { user: { email_address: attacker_email } }
    assert_redirected_to user_profile_url
    assert_equal original_email, user.reload.email_address

    get oidc_link_url
    assert_select "input[name='current_password']"
    assert_select "input[name='linking_state']", count: 0
    get "/auth/openid_connect/callback", params: { state: "forged-state" }, env: {
      "omniauth.auth" => oidc_auth(subject: "attacker-subject", email: attacker_email)
    }

    assert_redirected_to new_session_url
    put user_profile_url, params: { user: { email_address: original_email } }
    assert_equal original_email, user.reload.email_address
    assert_not user.identities.exists?(issuer: Oidc.issuer)
  end

  test "a recent password step-up authorizes first identity linking" do
    reauthenticate_for_first_link

    get oidc_link_url

    assert_response :success
    assert_select "form[action='#{openid_connect_path}']"
    assert_select "input[name='linking_state']", count: 1
  end

  test "an expired password step-up cannot authorize first identity linking" do
    reauthenticate_for_first_link

    travel Authentication::PASSWORD_REAUTHENTICATION_LIFETIME + 1.second do
      get oidc_link_url

      assert_response :success
      assert_select "input[name='current_password']"
      assert_select "form[action='#{openid_connect_path}']", count: 0
    end
  end

  test "password step-up cannot be carried to a replacement session" do
    reauthenticate_for_first_link
    Session.find_by!(token: parsed_cookies.signed[:session_token]).destroy!
    sign_in :jz

    get oidc_link_url

    assert_response :success
    assert_select "input[name='current_password']"
    assert_select "form[action='#{openid_connect_path}']", count: 0
  end

  test "required-mode transition still permits password proof for an unlinked user" do
    configure_oidc(
      "OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address
    )
    Oidc::Activation.stubs(:ready?).returns(true)

    reauthenticate_for_first_link
    get oidc_link_url

    assert_response :success
    assert_select "form[action='#{openid_connect_path}']"
  end

  test "an already-linked account must return as its bound subject" do
    user = users(:jz)
    identity = Identity.create!(user:, issuer: Oidc.issuer, subject: "bound-controller-subject")
    original_session = user.sessions.order(:id).last

    get oidc_link_url
    assert_select "input[name='current_password']", count: 0
    state = css_select("input[name='linking_state']").sole["value"]
    get "/auth/openid_connect/callback", params: { state: }, env: {
      "omniauth.auth" => oidc_auth(subject: "attacker-subject", email: user.email_address)
    }

    assert_redirected_to user_profile_url
    assert Session.exists?(original_session.id)
    assert_equal identity, user.identities.find_by!(issuer: Oidc.issuer)

    get oidc_link_url
    state = css_select("input[name='linking_state']").sole["value"]
    get "/auth/openid_connect/callback", params: { state: }, env: {
      "omniauth.auth" => oidc_auth(
        subject: identity.subject, email: nil, claims: { "email_verified" => nil }
      )
    }

    assert_redirected_to user_profile_url
    assert_not Session.exists?(original_session.id)
    assert_equal identity, Session.find_by!(token: parsed_cookies.signed[:session_token]).identity
  end

  test "wrong password cannot mint a linking intent" do
    patch oidc_link_url, params: { current_password: "wrong" }

    assert_redirected_to oidc_link_path
    assert_equal "Current password is incorrect.", flash[:alert]
    get oidc_link_url
    assert_select "input[name='current_password']"
    assert_select "input[name='linking_state']", count: 0
  end

  private
    def reauthenticate_for_first_link
      patch oidc_link_url, params: { current_password: "secret123456" }
      assert_redirected_to oidc_link_path
    end
end
