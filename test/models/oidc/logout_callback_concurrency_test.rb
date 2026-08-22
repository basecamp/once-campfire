require "test_helper"

class Oidc::LogoutCallbackConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    configure_oidc
    Oidc::LogoutToken.delete_all
    Oidc::Revocation.delete_all
    @identity = Identity.create!(
      user: users(:jz), issuer: Oidc.issuer, subject: "concurrent-logout-subject"
    )
  end

  teardown do
    Session.where(identity_id: @identity&.id).delete_all
    @identity&.delete
    Oidc::LogoutToken.delete_all
    Oidc::Revocation.delete_all
  end

  test "a callback committing concurrently before logout leaves no provider session" do
    issued_at = Time.current.to_i
    generation = Oidc::SessionGeneration.current!
    callback_guarded = Queue.new
    release_callback = Queue.new
    logout_started = Queue.new

    callback = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Session.transaction do
          user = User.lock_active!(@identity.user_id)
          Oidc::Revocation.guard_session!(
            issuer: @identity.issuer, subject: @identity.subject,
            sid: "concurrent-provider-session", issued_at:
          )
          callback_guarded << true
          release_callback.pop
          Session.create!(
            user:, identity: @identity, authentication_method: "oidc",
            oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
            oidc_session_generation: generation,
            oidc_session_id: "concurrent-provider-session", oidc_issued_at: issued_at,
            expires_at: 1.hour.from_now, user_agent: "Browser", ip_address: "192.0.2.1"
          )
        end
      end
    end
    callback_guarded.pop
    logout = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        logout_started << true
        Oidc::LogoutToken.consume!(
          "encoded",
          verifier: stub(verify: {
            "iss" => Oidc.issuer, "aud" => Oidc.client_id, "iat" => issued_at,
            "exp" => 5.minutes.from_now.to_i, "jti" => SecureRandom.uuid,
            "sub" => @identity.subject, "sid" => "concurrent-provider-session"
          })
        )
      end
    end
    logout_started.pop

    assert_predicate logout, :alive?
    release_callback << true
    callback.value
    assert logout.value

    assert_empty Session.where(identity_id: @identity.id)
    assert_equal issued_at, Oidc::Revocation.find_by!(identifier_type: "sid").revoked_before
  ensure
    release_callback << true if callback&.alive?
    callback&.join(2)
    logout&.join(2)
  end
end
