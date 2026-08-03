require "test_helper"
require "oidc/activation"

class Oidc::ActivationTest < ActiveSupport::TestCase
  setup do
    configure_oidc(
      "OIDC_MODE" => "required",
      "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address
    )
  end

  test "refuses activation while active users are unlinked" do
    record_verified_configuration
    error = Oidc::Activation.new.preflight_error

    assert_match(/active user\(s\) have not recently authenticated/, error)
  end

  test "activates only after users and an administrator are linked" do
    link_required_users

    Oidc::Activation.new.activate!(recovery_password: "secret123456")

    account = accounts(:signal).reload
    assert_equal Oidc.configuration.fingerprint, account.oidc_configuration_fingerprint
    assert account.oidc_required_at?
    assert Oidc::Activation.ready?
    assert_empty Session.where.not(authentication_method: "oidc")
    assert_empty Push::Subscription.where(session_id: nil)
  end

  test "activation requires proof of the recovery password before mutation" do
    link_required_users
    local_session_ids = Session.where.not(authentication_method: "oidc").ids

    error = assert_raises(Oidc::Activation::Error) do
      Oidc::Activation.new.activate!(recovery_password: "incorrect")
    end

    assert_match "could not be verified", error.message
    assert_equal local_session_ids, Session.where.not(authentication_method: "oidc").ids
    assert_nil accounts(:signal).reload.oidc_required_at
  end

  test "expired recovery rows do not poison steady-state readiness" do
    link_required_users
    Oidc::Activation.new.activate!(recovery_password: "secret123456")
    recovery = users(:jason).sessions.start!(user_agent: "Browser", ip_address: "192.0.2.1")
    recovery.update_column :expires_at, 1.minute.ago

    assert Oidc::Activation.ready?
  end

  test "secret rotation can be verified and activated without relinking identities" do
    link_required_users
    Oidc::Activation.new.activate!(recovery_password: "secret123456")
    provider_fingerprints = Identity.order(:id).pluck(:provider_fingerprint)

    configure_oidc(
      "OIDC_MODE" => "required",
      "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address,
      "OIDC_CLIENT_SECRET" => "rotated-secret"
    )
    assert_not Oidc::Activation.ready?
    record_verified_configuration
    verify_linked_identities

    Oidc::Activation.new.activate!(recovery_password: "secret123456")

    assert Oidc::Activation.ready?
    assert_equal provider_fingerprints, Identity.order(:id).pluck(:provider_fingerprint)
  end

  test "stale authentication proof cannot authorize destructive activation" do
    link_required_users
    accounts(:signal).update!(oidc_verified_at: 1.hour.ago)
    Identity.update_all(verified_at: 1.hour.ago)

    assert_no_difference -> { Session.count } do
      error = assert_raises(Oidc::Activation::Error) do
        Oidc::Activation.new.activate!(recovery_password: "secret123456")
      end
      assert_match "too old", error.message
    end
  end

  test "one stale identity blocks activation while account proof remains fresh" do
    link_required_users
    Identity.where.not(user: users(:jason)).first.update!(verified_at: 1.hour.ago)

    assert_no_difference -> { Session.count } do
      error = assert_raises(Oidc::Activation::Error) do
        Oidc::Activation.new.activate!(recovery_password: "secret123456")
      end
      assert_match "have not recently authenticated", error.message
    end
  end

  test "post-activation account changes do not poison global readiness" do
    link_required_users
    Oidc::Activation.new.activate!(recovery_password: "secret123456")

    users(:david).update!(role: :member, password: "a-new-known-password")

    assert Oidc::Activation.ready?
  end

  test "an optional-mode local join invalidates required-mode readiness until linked" do
    link_required_users
    Oidc::Activation.new.activate!(recovery_password: "secret123456")
    configure_oidc("OIDC_MODE" => "optional", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    newcomer = User.create!(
      name: "Newcomer", email_address: "newcomer@example.com", password: "secret123456"
    )
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)

    assert_equal "1 active user(s) are not linked to the configured provider", Oidc::Activation.readiness_error

    Identity.create!(user: newcomer, issuer: Oidc.issuer, subject: "newcomer-subject")

    assert Oidc::Activation.ready?
  end

  test "the bound recovery administrator cannot be reassigned through ordinary account mutations" do
    link_required_users
    Oidc::Activation.new.activate!(recovery_password: "secret123456")
    recovery = users(:jason)

    assert_not recovery.update(email_address: "replacement@example.com")
    assert_not recovery.update(role: :member)
    assert_not recovery.update(status: :deactivated)
    assert_equal users(:jason), accounts(:signal).reload.oidc_break_glass_user
    assert Oidc::Activation.ready?
  end

  test "recovery authentication keeps using the persisted binding when configuration changes" do
    link_required_users
    Oidc::Activation.new.activate!(recovery_password: "secret123456")
    configure_oidc(
      "OIDC_MODE" => "required",
      "OIDC_BREAK_GLASS_EMAIL" => users(:david).email_address,
      "OIDC_CLIENT_SECRET" => "rotated-secret"
    )

    assert_equal users(:jason), Oidc.break_glass_user
    assert_not Oidc::Activation.ready?
  end

  test "an invalid persisted recovery binding does not fall back to environment lookup" do
    link_required_users
    Oidc::Activation.new.activate!(recovery_password: "secret123456")
    users(:jason).update_column(:status, User.statuses.fetch("deactivated"))

    assert_nil Oidc.break_glass_user
    assert_equal "the recovery administrator binding is invalid", Oidc::Activation.readiness_error
  end

  test "rollback preparation requires confirmation and revokes every credential" do
    assert_raises(Oidc::Activation::Error) do
      Oidc::Activation.new.prepare_rollback!(confirmation: nil)
    end

    Oidc::Activation.new.prepare_rollback!(confirmation: "DELETE ALL SESSIONS")

    assert_empty Session.all
    assert_empty Push::Subscription.all
    assert_equal "rollback_prepared", accounts(:signal).reload.oidc_transition_state
  end

  test "rollback preparation refuses to strand JIT-provisioned users" do
    Identity.create!(
      user: users(:jz), issuer: Oidc.issuer, subject: "jit-rollback-subject", provisioned: true
    )

    error = assert_raises(Oidc::Activation::Error) do
      Oidc::Activation.new.prepare_rollback!(confirmation: "DELETE ALL SESSIONS")
    end

    assert_match "JIT-provisioned users", error.message
    assert Session.exists?
  end

  test "rollback preparation refuses to strand passwordless users" do
    User.create!(name: "Passwordless", email_address: "passwordless@example.com", role: :member)

    error = assert_raises(Oidc::Activation::Error) do
      Oidc::Activation.new.prepare_rollback!(confirmation: "DELETE ALL SESSIONS")
    end

    assert_match "without local passwords", error.message
    assert Session.exists?
  end

  test "rollback cancellation remains quarantined outside required mode" do
    accounts(:signal).update!(oidc_transition_state: "rollback_prepared", oidc_break_glass_user: users(:jason))

    %w[ disabled optional ].each do |mode|
      configure_oidc("OIDC_MODE" => mode, "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
      assert_raises(Oidc::Activation::Error) do
        Oidc::Activation.new.cancel_rollback!(
          confirmation: "RESUME OIDC", recovery_password: "secret123456"
        )
      end
      assert_equal "rollback_prepared", accounts(:signal).reload.oidc_transition_state
    end
  end

  test "rollback preparation can be canceled only with confirmation and password proof" do
    link_required_users
    Oidc::Activation.new.activate!(recovery_password: "secret123456")
    Oidc::Activation.new.prepare_rollback!(confirmation: "DELETE ALL SESSIONS")

    assert_raises(Oidc::Activation::Error) do
      Oidc::Activation.new.cancel_rollback!(confirmation: "RESUME OIDC", recovery_password: "incorrect")
    end
    assert_equal "rollback_prepared", accounts(:signal).reload.oidc_transition_state

    Oidc::Activation.new.cancel_rollback!(
      confirmation: "RESUME OIDC", recovery_password: "secret123456"
    )

    assert_nil accounts(:signal).reload.oidc_transition_state
    assert_not Oidc::Activation.ready?
  end

  private
    def link_required_users
      User.active.without_bots.where.not(id: users(:jason).id).find_each do |user|
        Identity.create!(
          user:, issuer: Oidc.issuer, subject: "activation-#{user.id}",
          verified_configuration_fingerprint: Oidc.configuration.fingerprint,
          verified_at: Time.current
        )
      end
      record_verified_configuration
    end

    def verify_linked_identities
      Identity.update_all(
        verified_configuration_fingerprint: Oidc.configuration.fingerprint,
        verified_at: Time.current
      )
    end

    def record_verified_configuration
      accounts(:signal).update!(
        oidc_verified_configuration_fingerprint: Oidc.configuration.fingerprint,
        oidc_verified_at: Time.current
      )
    end
end
