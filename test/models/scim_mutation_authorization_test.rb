require "test_helper"

class ScimMutationAuthorizationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    configure_oidc
    @user = users(:david)
    Identity.where(issuer: Oidc.issuer, subject: "mutation-race-subject").delete_all
    @identity = Identity.create!(user: @user, issuer: Oidc.issuer, subject: "mutation-race-subject")
    User.any_instance.stubs(:disconnect_remote_connections)
  end

  teardown do
    Identity.where(issuer: Oidc.issuer, subject: "mutation-race-subject").delete_all
  end

  test "SCIM deactivation committing first prevents recording a search" do
    result = mutate_after_deactivation do
      Search.record_for!(User.find(@user.id), "must-not-be-recorded")
    end

    assert_kind_of User::AuthorizationError, result
    assert_not Search.exists?(user_id: @user.id, query: "must-not-be-recorded")
  end

  test "SCIM deactivation committing first prevents creating a boost" do
    message = messages(:first)
    original_count = message.boosts.count

    result = mutate_after_deactivation do
      Boost.create_by!(
        message: Message.find(message.id), actor: User.find(@user.id),
        attributes: { content: "must-not-be-created" }
      )
    end

    assert_kind_of User::AuthorizationError, result
    assert_equal original_count, message.boosts.count
  end

  private
    def mutate_after_deactivation(&mutation)
      deactivated = Queue.new
      release = Queue.new
      result = Queue.new
      deactivation = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          User::MutationFence.with(@user.id) do
            User.find(@user.id).deactivate_from_identity_provider!(
              identity: Identity.find(@identity.id), issuer: Oidc.issuer
            )
            deactivated << true
            release.pop
          end
        end
      end
      deactivated.pop
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          mutation.call
          result << true
        rescue StandardError => error
          result << error
        end
      end

      assert_predicate worker, :alive?
      release << true
      deactivation.value
      worker.join
      result.pop
    ensure
      release << true if deactivation&.alive?
      deactivation&.join(2)
      worker&.join(2)
    end
end
