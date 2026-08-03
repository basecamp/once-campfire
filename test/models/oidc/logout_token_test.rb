require "test_helper"

class Oidc::LogoutTokenTest < ActiveSupport::TestCase
  setup do
    configure_oidc
    @identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "logout-subject")
    @other_identity = Identity.create!(user: users(:kevin), issuer: Oidc.issuer, subject: "other-subject")
  end

  test "sid logout revokes only sessions with the exact provider binding" do
    matching = federated_session(@identity, sid: "shared-provider-session")
    same_user_other_sid = federated_session(@identity, sid: "other-provider-session")
    other_user = federated_session(@other_identity, sid: "other-user-session")
    subscription = push_subscriptions(:jz_chrome)
    subscription.update!(session: matching)

    consume "sid" => matching.oidc_session_id, "sub" => nil

    assert_not Session.exists?(matching.id)
    assert_not Push::Subscription.exists?(subscription.id)
    assert Session.exists?(same_user_other_sid.id)
    assert Session.exists?(other_user.id)
  end

  test "subject logout revokes every federated session for the exact issuer subject" do
    first = federated_session(@identity, sid: "first-provider-session")
    second = federated_session(@identity, sid: "second-provider-session")
    other = federated_session(@other_identity, sid: "other-provider-session")
    local = sessions(:jz_chrome)

    consume "sub" => @identity.subject, "sid" => nil

    assert_not Session.exists?(first.id)
    assert_not Session.exists?(second.id)
    assert Session.exists?(other.id)
    assert Session.exists?(local.id)
  end

  test "matching sid and subject revoke only their common binding" do
    session = federated_session(@identity, sid: "combined-provider-session")

    consume "sub" => @identity.subject, "sid" => session.oidc_session_id

    assert_not Session.exists?(session.id)
  end

  test "mismatched or ambiguous sid semantics reject without consuming or revoking" do
    first = federated_session(@identity, sid: "ambiguous-provider-session")
    second = federated_session(@other_identity, sid: "ambiguous-provider-session")

    assert_raises(Oidc::LogoutTokenVerifier::Invalid) do
      consume "sub" => @identity.subject, "sid" => "ambiguous-provider-session"
    end

    assert Session.exists?(first.id)
    assert Session.exists?(second.id)
    assert_not Oidc::LogoutToken.exists?
    assert_not Oidc::Revocation.where.not(revoked_before: nil).exists?
  end

  test "never revokes sessions from another issuer" do
    current = federated_session(@identity, sid: "cross-issuer-session")
    old_identity = Identity.create!(
      user: users(:david), issuer: "https://other-idp.example.com", subject: @identity.subject,
      provider_fingerprint: Oidc.provider_fingerprint
    )
    other_issuer = federated_session(old_identity, sid: current.oidc_session_id)

    consume "sid" => current.oidc_session_id, "sub" => nil

    assert_not Session.exists?(current.id)
    assert Session.exists?(other_issuer.id)
  end

  test "unknown targets are idempotent while exact token replay is rejected" do
    claims = logout_claims.merge("sub" => "unknown-subject", "sid" => nil, "jti" => "stable-jti")

    assert Oidc::LogoutToken.consume!("encoded", verifier: verifier_for(claims))
    assert_raises(Oidc::LogoutToken::Replay) do
      Oidc::LogoutToken.consume!("encoded", verifier: verifier_for(claims))
    end

    assert_equal 1, Oidc::LogoutToken.count
    assert_not_equal "stable-jti", Oidc::LogoutToken.sole.jti_digest

    assert Oidc::LogoutToken.consume!(
      "different", verifier: verifier_for(claims.merge("jti" => "different-jti"))
    )
  end

  test "sid logout before callback rejects a session at the watermark" do
    issued_at = Time.current.to_i
    consume "sub" => nil, "sid" => "not-yet-created", "iat" => issued_at

    error = assert_raises(Identity::AuthenticationError) do
      federated_session(@identity, sid: "not-yet-created", issued_at:)
    end

    assert_equal "provider_session_revoked", error.message
    assert federated_session(@identity, sid: "different-session", issued_at:)
  end

  test "subject logout before a JIT first login rolls back the user identity and session" do
    configure_oidc("OIDC_JIT_PROVISIONING" => "true")
    subject = "jit-after-logout-subject"
    issued_at = Time.current.to_i
    consume "sub" => subject, "sid" => nil, "iat" => issued_at
    auth = oidc_auth(
      subject:, email: "jit-after-logout@example.com",
      claims: { "iat" => issued_at, "sid" => "jit-provider-session" }
    )

    assert_no_changes -> { [ User.count, Identity.count, Session.count ] } do
      error = assert_raises(Identity::AuthenticationError) do
        Account.transaction do
          identity = Identity.authenticate(auth)
          identity.user.sessions.start!(
            user_agent: "Browser", ip_address: "192.0.2.1", identity:,
            **Identity.provider_session_attributes(auth)
          )
        end
      end
      assert_equal "provider_session_revoked", error.message
    end
  end

  test "out-of-order logout advances watermarks without deleting newer sessions" do
    older_iat = 30.seconds.ago.to_i
    logout_iat = 20.seconds.ago.to_i
    newer_iat = 10.seconds.ago.to_i
    older = federated_session(@identity, sid: "ordered-session", issued_at: older_iat)
    newer = federated_session(@identity, sid: "ordered-session", issued_at: newer_iat)

    consume "sub" => @identity.subject, "sid" => "ordered-session", "iat" => logout_iat

    assert_not Session.exists?(older.id)
    assert Session.exists?(newer.id)
    watermark = Oidc::Revocation.find_by!(identifier_type: "sid")
    assert_equal logout_iat, watermark.revoked_before

    consume "sub" => @identity.subject, "sid" => "ordered-session",
      "iat" => older_iat, "jti" => "out-of-order-jti"

    assert_equal logout_iat, watermark.reload.revoked_before
    assert Session.exists?(newer.id)
    assert_raises(Identity::AuthenticationError) do
      federated_session(@identity, sid: "ordered-session", issued_at: logout_iat)
    end
    watermark_expires_at = watermark.reload.expires_at
    travel 1.minute do
      assert federated_session(@identity, sid: "ordered-session", issued_at: newer_iat + 1)
    end
    assert_equal watermark_expires_at, watermark.reload.expires_at
  end

  test "expired replay evidence is pruned" do
    Oidc::LogoutToken.create!(
      provider_fingerprint: Oidc.provider_fingerprint,
      jti_digest: Digest::SHA256.hexdigest("expired-jti"),
      expires_at: 1.minute.ago
    )

    consume "sub" => "unknown-subject", "sid" => nil

    assert_not Oidc::LogoutToken.exists?(jti_digest: Digest::SHA256.hexdigest("expired-jti"))
  end

  test "expired revocation guards are pruned with bounded retention" do
    Oidc::Revocation.create!(
      issuer_fingerprint: Digest::SHA256.hexdigest(Oidc.issuer), identifier_type: "sid",
      identifier_digest: Digest::SHA256.hexdigest("expired-sid"), revoked_before: 1.hour.ago.to_i,
      expires_at: 1.minute.ago
    )

    consume "sub" => "unknown-subject", "sid" => nil

    assert_not Oidc::Revocation.exists?(identifier_digest: Digest::SHA256.hexdigest("expired-sid"))
  end

  private
    def consume(overrides)
      Oidc::LogoutToken.consume!(
        "encoded", verifier: verifier_for(logout_claims.merge(overrides))
      )
    end

    def verifier_for(claims)
      stub(verify: claims)
    end

    def logout_claims
      {
        "iss" => Oidc.issuer,
        "aud" => Oidc.client_id,
        "iat" => Time.current.to_i,
        "exp" => 5.minutes.from_now.to_i,
        "jti" => SecureRandom.uuid,
        "sub" => @identity.subject,
        "sid" => "provider-session"
      }
    end

    def federated_session(identity, sid:, issued_at: Time.current.to_i)
      identity.user.sessions.start!(
        user_agent: "Browser", ip_address: "192.0.2.1", identity:, oidc_session_id: sid,
        oidc_issued_at: issued_at
      )
    end
end
