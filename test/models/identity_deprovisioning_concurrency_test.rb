require "test_helper"

class IdentityDeprovisioningConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  SUBJECT = "concurrent-pre-link-deprovisioning"
  EMAIL = "concurrent-pre-link-deprovisioning@example.com"

  setup do
    configure_oidc("OIDC_JIT_PROVISIONING" => "true")
    cleanup_records
    User.any_instance.stubs(:disconnect_remote_connections)
  end

  teardown do
    cleanup_records
  end

  test "a tombstone committing first blocks a concurrent JIT identity creation" do
    committed = Queue.new
    release_deprovisioning = Queue.new
    result = Queue.new

    deprovisioning = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User::MutationFence.with_identity_subject(issuer: Oidc.issuer, subject: SUBJECT) do
          Identity::Deprovisioning.deprovision!(issuer: Oidc.issuer, subject: SUBJECT)
          committed << true
          release_deprovisioning.pop
        end
      end
    end
    committed.pop

    authentication = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Identity.authenticate(oidc_auth(subject: SUBJECT, email: EMAIL))
        result << :authenticated
      rescue StandardError => error
        result << error
      end
    end

    assert_predicate authentication, :alive?
    release_deprovisioning << true
    deprovisioning.value
    authentication.join

    error = result.pop
    assert_kind_of Identity::AuthenticationError, error
    assert_equal "identity_revoked", error.message
    assert_not User.exists?(email_address: EMAIL)
    assert_not Identity.exists?(issuer: Oidc.issuer, subject: SUBJECT)
  ensure
    release_deprovisioning << true if deprovisioning&.alive?
    deprovisioning&.join(2)
    authentication&.join(2)
  end

  test "a flow callback holds the subject fence before its DB transaction while SCIM waits" do
    callback_in_transaction = Queue.new
    release_callback = Queue.new
    auth = oidc_auth(subject: SUBJECT, email: EMAIL)
    flow = consumed_flow

    callback = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Identity.with_authentication_fence(auth) do |authentication|
          flow.finalize! do
            callback_in_transaction << ActiveRecord::Base.connection.transaction_open?
            release_callback.pop
            authentication.complete!
          end
        end
      end
    end
    assert callback_in_transaction.pop

    deprovisioning = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Identity::Deprovisioning.deprovision!(issuer: Oidc.issuer, subject: SUBJECT)
      end
    end

    assert_predicate deprovisioning, :alive?
    release_callback << true
    callback.value
    identity = deprovisioning.value

    assert_predicate identity, :provider_revoked_at?
    assert_predicate identity.user, :deactivated?
    assert Identity::Deprovisioning.blocked?(issuer: Oidc.issuer, subject: SUBJECT)
  ensure
    release_callback << true if callback&.alive?
    callback&.join(2)
    deprovisioning&.join(2)
  end

  private
    def cleanup_records
      user_ids = Identity.where(issuer: Oidc.issuer, subject: SUBJECT).pluck(:user_id)
      User.where(id: user_ids).find_each(&:destroy!)
      Identity::Deprovisioning.where(issuer: Oidc.issuer, subject: SUBJECT).delete_all
      User.where(email_address: EMAIL).find_each(&:destroy!)
    end

    def consumed_flow
      browser_token = SecureRandom.urlsafe_base64(32)
      state = SecureRandom.urlsafe_base64(32)
      Oidc::Flow.start!(
        state:, nonce: "nonce", pkce_verifier: "verifier", browser_token:,
        initiating_session_id: nil, linking_intent: nil
      )
      Oidc::Flow.consume!(state:, browser_token:)
    end
end
