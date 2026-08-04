require "test_helper"

class Users::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    sign_in :david
  end

  test "show" do
    get user_profile_url

    assert_response :success
  end

  test "update" do
    put user_profile_url, params: { user: { name: "John Doe", bio: "Acrobat" } }

    assert_redirected_to user_profile_url
    assert_equal "John Doe", users(:david).reload.name
    assert_equal "Acrobat", users(:david).bio
    assert_equal "david@37signals.com", users(:david).email_address
  end

  test "changing a password account email requires the current password" do
    original_email = users(:david).email_address

    put user_profile_url, params: { user: { email_address: "attacker@example.com" } }

    assert_redirected_to user_profile_url
    assert_equal "Current password is incorrect.", flash[:alert]
    assert_equal original_email, users(:david).reload.email_address

    put user_profile_url, params: {
      user: { email_address: " VERIFIED-CHANGE@EXAMPLE.COM ", current_password: "secret123456" }
    }

    assert_redirected_to user_profile_url
    assert_equal "verified-change@example.com", users(:david).reload.email_address
    assert_equal users(:david).email_address, users(:david).normalized_email_address
  end

  test "changing an email to a case variant owned by another user is rejected" do
    original_email = users(:david).email_address

    put user_profile_url, params: {
      user: { email_address: " JASON@37SIGNALS.COM ", current_password: "secret123456" }
    }

    assert_redirected_to user_profile_url
    assert_equal "Email address is already in use.", flash[:alert]
    assert_equal original_email, users(:david).reload.email_address
    assert_equal original_email, users(:david).normalized_email_address
  end

  test "updates are limited to the current user" do
    put user_profile_url(users(:jason)), params: { user: { name: "John Doe" } }

    assert_equal "Jason", users(:jason).reload.name
  end

  test "required mode rejects password assignment for ordinary federated users" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    Oidc::Activation.stubs(:ready?).returns(true)
    identity = Identity.create!(user: users(:david), issuer: Oidc.issuer, subject: "profile-password-subject")
    current_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    current_session.update_columns(
      authentication_method: "oidc",
      identity_id: identity.id,
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_issued_at: Time.current.to_i,
      expires_at: 1.hour.from_now
    )
    accounts(:signal).update!(
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_required_at: Time.current,
      oidc_break_glass_user: users(:jason)
    )
    original_digest = users(:david).password_digest
    use_oidc_origin

    put user_profile_path, params: { user: { password: "attacker-chosen-password" } }

    assert_redirected_to user_profile_url
    assert_equal original_digest, users(:david).reload.password_digest
  end

  test "changing the recovery password requires the current password" do
    recovery_user = users(:david)
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => recovery_user.email_address)
    Oidc::Activation.stubs(:ready?).returns(true)
    identity = Identity.create!(user: recovery_user, issuer: Oidc.issuer, subject: "recovery-profile-subject")
    current_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    current_session.update_columns(
      authentication_method: "oidc",
      identity_id: identity.id,
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_issued_at: Time.current.to_i,
      expires_at: 1.hour.from_now
    )
    accounts(:signal).update!(
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_required_at: Time.current,
      oidc_break_glass_user: recovery_user
    )
    original_digest = recovery_user.password_digest
    use_oidc_origin

    put user_profile_path, params: { user: { password: "attacker-chosen-password" } }

    assert_redirected_to user_profile_url
    assert_equal "Current password is incorrect.", flash[:alert]
    assert_equal original_digest, recovery_user.reload.password_digest

    put user_profile_path, params: {
      user: { current_password: "secret123456", password: "new-recovery-password" }
    }

    assert_redirected_to user_profile_url
    assert recovery_user.reload.authenticate_password("new-recovery-password")
  end

  test "changing a password rotates the current session and revokes other credentials" do
    user = users(:david)
    stale_user = User.find(user.id)
    current_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    old_token = current_session.token
    other_session = Session.start!(
      user:, user_agent: "stolen browser", ip_address: "203.0.113.90", authentication_method: "password"
    )
    browser_transfer = CredentialIntent.exchange_transfer!(user.transfer_id)
    user.transfer_id

    put user_profile_url, params: {
      user: { current_password: "secret123456", password: "new-password-123456" }
    }

    assert_redirected_to user_profile_url
    assert user.reload.authenticate_password("new-password-123456")
    assert_equal current_session.id, Session.find_by!(token: parsed_cookies.signed[:session_token]).id
    assert_not_equal old_token, parsed_cookies.signed[:session_token]
    assert_not Session.exists?(token: old_token)
    assert_not Session.exists?(id: other_session.id)
    assert_not CredentialIntent.valid_transfer?(browser_transfer)
    assert_not CredentialIntent.where(user:, purpose: "transfer_grant").exists?
    stale_grant = stale_user.transfer_id
    assert_raises(CredentialIntent::Invalid) { CredentialIntent.exchange_transfer!(stale_grant) }
  end

  test "activated required mode makes the recovery email read only and rejects a forged change" do
    recovery_user = users(:david)
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => recovery_user.email_address)
    Oidc::Activation.stubs(:ready?).returns(true)
    accounts(:signal).update!(
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_required_at: Time.current,
      oidc_break_glass_user: recovery_user
    )
    Session.find_by!(token: parsed_cookies.signed[:session_token]).update_columns(
      authentication_method: "password", expires_at: 1.hour.from_now
    )
    use_oidc_origin

    get user_profile_path
    assert_select "input[name='user[email_address]'][readonly]"
    assert_select "#recovery-email-explanation", text: /Rotate the recovery administrator/

    put user_profile_path, params: { user: { email_address: " DAVID@37SIGNALS.COM " } }
    assert_redirected_to user_profile_url
    assert_equal "david@37signals.com", recovery_user.reload.email_address

    put user_profile_path, params: { user: { email_address: "new-recovery@example.com" } }

    assert_redirected_to user_profile_url
    assert_equal "The recovery email cannot be changed while required single sign-on is active.", flash[:alert]
    assert_equal "david@37signals.com", recovery_user.reload.email_address
  end

  test "rate limits current password verification" do
    Users::ProfilesController::PASSWORD_ATTEMPT_LIMIT.times do
      put user_profile_url, params: { user: { current_password: "wrong", password: "not-used-password" } }
      assert_redirected_to user_profile_url
      assert_equal "Current password is incorrect.", flash[:alert]
    end

    put user_profile_url, params: { user: { current_password: "secret123456", password: "blocked-password" } }

    assert_response :too_many_requests
    assert_select ".flash__message", text: /Too many password attempts/
    assert_not users(:david).reload.authenticate_password("blocked-password")
  end

  test "does not verify the current password when rate limit storage returns nil" do
    original_digest = users(:david).password_digest
    @cache.stubs(:increment).returns(nil)
    User.any_instance.expects(:authenticate_password).never

    put user_profile_url, params: {
      user: { current_password: "secret123456", password: "blocked-password" }
    }

    assert_response :service_unavailable
    assert_equal Oidc::POLICY_UNAVAILABLE_MESSAGE, response.body
    assert_equal original_digest, users(:david).reload.password_digest
  end

  test "does not verify the current password when rate limit storage times out" do
    original_digest = users(:david).password_digest
    @cache.stubs(:increment).raises(Timeout::Error, "cache timeout")
    User.any_instance.expects(:authenticate_password).never

    put user_profile_url, params: {
      user: { current_password: "secret123456", password: "blocked-password" }
    }

    assert_response :service_unavailable
    assert_equal Oidc::POLICY_UNAVAILABLE_MESSAGE, response.body
    assert_equal original_digest, users(:david).reload.password_digest
  end

  test "returns service unavailable when policy fails after the request readiness check" do
    policy_reads = sequence("policy reads")
    Oidc.expects(:rollback_prepared?).in_sequence(policy_reads).returns(false)
    Oidc.expects(:rollback_prepared?).in_sequence(policy_reads).raises(
      Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE
    )

    get user_profile_url

    assert_response :service_unavailable
    assert_equal Oidc::POLICY_UNAVAILABLE_MESSAGE, response.body
  end

  private
    def use_oidc_origin
      session_token = cookies[:session_token]
      reset!
      host! Oidc.configuration.redirect_host
      https!
      cookies[:session_token] = session_token
    end
end
