require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup do
    configure_oidc
    @identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "session-subject")
  end

  test "federated sessions receive an absolute expiry" do
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity: @identity,
      oidc_session_id: "provider-session", oidc_issued_at: Time.current.to_i
    )

    assert_in_delta Oidc.session_lifetime_seconds.seconds.from_now.to_i, session.expires_at.to_i, 2
    assert_equal "provider-session", session.oidc_session_id
    assert session.valid_for_authentication?
  end

  test "expired federated sessions are invalid" do
    session = users(:jz).sessions.create!(
      identity: @identity, authentication_method: "oidc", expires_at: 1.second.ago,
      oidc_issued_at: Time.current.to_i
    )

    assert_not session.valid_for_authentication?
  end

  test "required mode preserves local sessions until activation" do
    configure_oidc("OIDC_MODE" => "required")
    session = users(:jz).sessions.start!(user_agent: "Browser", ip_address: "192.0.2.1")

    assert session.valid_for_authentication?

    activate_required_policy

    assert_not session.valid_for_authentication?
  end

  test "activated required mode prevents new ordinary local sessions" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:david).email_address)
    activate_required_policy

    session = users(:jz).sessions.build(authentication_method: "password")

    assert_not session.valid?
    assert_includes session.errors[:authentication_method], "is disabled by required single sign-on"
  end

  test "required mode only accepts identities from the configured issuer" do
    configure_oidc("OIDC_MODE" => "required")
    old_identity = Identity.create!(
      user: users(:kevin), issuer: "https://old-idp.example.com", subject: "old-provider-subject",
      provider_fingerprint: Digest::SHA256.hexdigest("old-provider")
    )
    session = users(:kevin).sessions.create!(
      identity: old_identity, authentication_method: "oidc", expires_at: 1.hour.from_now,
      oidc_issued_at: Time.current.to_i
    )
    activate_required_policy

    assert_not session.valid_for_authentication?
  end

  test "required mode permits the configured administrator recovery account" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:david).email_address)
    session = users(:david).sessions.start!(user_agent: "Browser", ip_address: "192.0.2.1")
    activate_required_policy

    assert session.valid_for_authentication?
    assert session.expires_at.future?
  end

  test "identity must belong to the session user" do
    session = users(:david).sessions.build(identity: @identity)

    assert_not session.valid?
    assert_includes session.errors[:identity], "must belong to the session user"
  end

  test "database rejects OIDC sessions without an expiry" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Session.insert_all!([ {
        user_id: users(:jz).id,
        identity_id: @identity.id,
        authentication_method: "oidc",
        oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
        oidc_issued_at: Time.current.to_i,
        token: SecureRandom.hex,
        last_active_at: Time.current,
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end
  end

  test "local sessions cannot carry a provider session identifier" do
    session = users(:jz).sessions.build(authentication_method: "password", oidc_session_id: "provider-session")

    assert_not session.valid?
    assert_includes session.errors[:identity], "must match the authentication method"

    assert_raises(ActiveRecord::StatementInvalid) do
      Session.where(id: sessions(:jz_chrome).id).update_all(oidc_session_id: "provider-session")
    end
  end

  test "provider session identifiers are byte bounded" do
    session = users(:jz).sessions.build(
      identity: @identity, authentication_method: "oidc", expires_at: 1.hour.from_now,
      oidc_session_id: "é" * 128, oidc_issued_at: Time.current.to_i
    )

    assert_not session.valid?
    assert_includes session.errors[:oidc_session_id], "is too long"
  end

  test "database rejects an identity owned by another session user" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Session.insert_all!([ {
        user_id: users(:david).id,
        identity_id: @identity.id,
        authentication_method: "oidc",
        oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
        oidc_issued_at: Time.current.to_i,
        expires_at: 1.hour.from_now,
        token: SecureRandom.hex,
        last_active_at: Time.current,
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end
  end

  test "disabling OIDC invalidates existing federated sessions" do
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity: @identity,
      oidc_issued_at: Time.current.to_i
    )
    Oidc.configuration = Oidc::Configuration.new({})

    assert_not session.valid_for_authentication?
  end

  test "rotating an exact OIDC configuration invalidates its old sessions" do
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity: @identity,
      oidc_issued_at: Time.current.to_i
    )

    configure_oidc("OIDC_CLIENT_SECRET" => "rotated-secret")

    assert_not session.valid_for_authentication?
  end

  test "broadening a trusted proxy prefix invalidates its old sessions" do
    proxy_configuration = {
      "DISABLE_SSL" => "true",
      "OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/24"
    }
    configure_oidc(proxy_configuration)
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity: @identity,
      oidc_issued_at: Time.current.to_i
    )

    configure_oidc(proxy_configuration.merge("OIDC_TRUSTED_PROXY_CIDRS" => "10.20.0.0/16"))

    assert_not session.valid_for_authentication?
  end

  test "rollback quarantine rejects old-image sessions in every OIDC mode" do
    accounts(:signal).update!(oidc_transition_state: "rollback_prepared")

    %w[ disabled optional required ].each do |mode|
      overrides = mode == "disabled" ? { "OIDC_MODE" => "disabled" } : { "OIDC_MODE" => mode }
      configure_oidc(overrides)

      assert_not sessions(:jz_chrome).valid_for_authentication?
      assert_not_includes Session.authenticatable, sessions(:jz_chrome)
    end
  end

  test "policy read uncertainty exposes no authenticatable sessions or push subscriptions" do
    Oidc.stubs(:rollback_prepared?).raises(Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE)

    assert_empty Session.authenticatable
    assert_empty Push::Subscription.with_current_session
  end

  test "database errors raise a typed policy failure" do
    configure_oidc("OIDC_MODE" => "required")
    Account.stubs(:table_exists?).raises(ActiveRecord::StatementInvalid, "database unavailable")

    assert_raises(Oidc::PolicyUnavailable) { Oidc.rollback_prepared? }
    assert_raises(Oidc::PolicyUnavailable) { Oidc.required_active? }
  end

  test "missing pre-migration policy columns remain permissive" do
    configure_oidc("OIDC_MODE" => "required")
    Account.stubs(:table_exists?).returns(true)
    Account.stubs(:column_names).returns(%w[ id ])

    assert_not Oidc.rollback_prepared?
    assert_not Oidc.required_active?
  end

  private
    def activate_required_policy
      recovery_user = Oidc.break_glass_user
      accounts(:signal).update!(
        oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
        oidc_required_at: Time.current,
        oidc_break_glass_user: recovery_user,
        oidc_transition_state: nil
      )
    end
end
