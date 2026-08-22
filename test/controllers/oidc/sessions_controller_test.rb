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

  test "callback acquires the subject fence before fencing replacement of an existing cookie session" do
    identity = Identity.create!(
      user: users(:jz), issuer: Oidc.issuer, subject: "fenced-callback-subject"
    )
    sign_in :jz
    existing_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    subject_acquired_before_user = false
    observed_fences = false
    authentication = Object.new
    authentication.define_singleton_method(:complete!) do |**|
      observed_fences = User::MutationFence.held?(identity.user_id) &&
        User::MutationFence.identity_subject_held?(issuer: identity.issuer, subject: identity.subject)
      identity
    end
    original_authentication_fence = Identity.method(:with_authentication_fence)
    Identity.define_singleton_method(:with_authentication_fence) do |auth, &operation|
      original_authentication_fence.call(auth) do
        subject_acquired_before_user = !User::MutationFence.held?(identity.user_id)
        operation.call authentication
      end
    end

    get "/auth/openid_connect/callback", env: {
      "omniauth.auth" => oidc_auth(
        subject: identity.subject, email: identity.user.email_address
      )
    }

    assert_redirected_to root_url
    assert subject_acquired_before_user
    assert observed_fences
    assert_not Session.exists?(existing_session.id)
  ensure
    if original_authentication_fence
      Identity.define_singleton_method(:with_authentication_fence, original_authentication_fence)
    end
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

  test "returns service unavailable when the identity mutation fence is unavailable" do
    User::MutationFence.stubs(:with_identity_subject)
      .raises(User::MutationFence::Unavailable, "unavailable")

    get "/auth/openid_connect/callback", env: {
      "omniauth.auth" => oidc_auth(email: users(:jz).email_address)
    }

    assert_response :service_unavailable
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
    Identity::PreparedAuthentication.any_instance.expects(:complete!).never
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

class Oidc::SessionDeprovisioningConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  SUBJECT = "concurrent-controller-deprovisioning"
  EMAIL = "concurrent-controller-deprovisioning@example.com"

  setup do
    configure_oidc
    host! Oidc.configuration.redirect_host
    https!
    cleanup_records
    @user = User.create!(
      name: "Concurrent callback user", email_address: EMAIL,
      password: "secret123456", role: :member
    )
    @identity = Identity.create!(user: @user, issuer: Oidc.issuer, subject: SUBJECT)
    User.any_instance.stubs(:disconnect_remote_connections)
    Oidc::Activation.stubs(:record_successful_authentication!)
    sign_in @user
  end

  teardown do
    cleanup_records
  end

  test "callback and SCIM deprovisioning terminate with subject-before-user ordering" do
    user_fence_entered = Queue.new
    release_user_fence = Queue.new
    subject_fence_entered = Queue.new
    deprovisioning_started = Queue.new
    callback_result = Queue.new
    original_authentication_fence = Identity.method(:with_authentication_fence)
    callback = nil
    Identity.define_singleton_method(:with_authentication_fence) do |auth, &operation|
      original_authentication_fence.call(auth) do |authentication|
        subject_fence_entered << true if Thread.current == callback
        operation.call authentication
      end
    end

    user_fence = Thread.new do
      User::MutationFence.with(@user.id) do
        user_fence_entered << true
        release_user_fence.pop
      end
    end
    user_fence_entered.pop

    callback_start = Queue.new
    callback = Thread.new do
      callback_start.pop
      get "/auth/openid_connect/callback", env: {
        "omniauth.auth" => oidc_auth(subject: SUBJECT, email: EMAIL)
      }
      callback_result << :completed
    rescue Exception => error
      callback_result << error
    end
    callback_start << true
    Timeout.timeout(5) { subject_fence_entered.pop }

    deprovisioning = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        deprovisioning_started << true
        Identity::Deprovisioning.deprovision!(issuer: Oidc.issuer, subject: SUBJECT)
      end
    end
    deprovisioning_started.pop
    assert_predicate deprovisioning, :alive?

    release_user_fence << true
    assert user_fence.join(5), "user fence did not release"
    assert callback.join(5), "OIDC callback deadlocked"
    assert deprovisioning.join(5), "SCIM deprovisioning deadlocked"

    assert_equal :completed, callback_result.pop
    assert_predicate @user.reload, :deactivated?
    assert_not Session.exists?(user_id: @user.id)
    assert Identity::Deprovisioning.blocked?(issuer: Oidc.issuer, subject: SUBJECT)
  ensure
    release_user_fence << true if user_fence&.alive?
    user_fence&.join(2)
    callback&.join(2)
    deprovisioning&.join(2)
    if original_authentication_fence
      Identity.define_singleton_method(:with_authentication_fence, original_authentication_fence)
    end
  end

  private
    def cleanup_records
      user_ids = Identity.where(issuer: Oidc.issuer, subject: SUBJECT).pluck(:user_id)
      User.where(id: user_ids).find_each(&:destroy!)
      Identity::Deprovisioning.where(issuer: Oidc.issuer, subject: SUBJECT).delete_all
      User.where(email_address: EMAIL).find_each(&:destroy!)
    end
end
