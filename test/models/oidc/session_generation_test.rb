require "test_helper"

class Oidc::SessionGenerationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  SUBJECT = "bounded-generation-retirement"

  setup do
    configure_oidc
    cleanup_records
    @identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: SUBJECT)
  end

  teardown do
    cleanup_records
  end

  test "retires a bounded batch through session destroy disconnect broadcasts" do
    first = federated_session("first-generation-session")
    second = federated_session("second-generation-session")
    third = federated_session("third-generation-session")
    subscription = push_subscriptions(:jz_chrome)
    subscription.update!(session: first)
    channels = [ first, second, third ].to_h { [ _1.id, internal_channel(_1) ] }
    Oidc::SessionGeneration.stubs(:retirement_batch_size).returns(1)

    configure_oidc("OIDC_CLIENT_SECRET" => "next-generation-secret")
    Oidc::SessionGeneration.current!

    assert_not Session.exists?(first.id)
    assert Session.exists?(second.id)
    assert Session.exists?(third.id)
    assert_not Push::Subscription.exists?(subscription.id)
    assert_disconnect_broadcast channels.fetch(first.id)
    assert_empty broadcasts(channels.fetch(second.id))

    assert_not Oidc::SessionGeneration.ready?
    assert_not Session.exists?(second.id)
    assert Session.exists?(third.id)
    assert_disconnect_broadcast channels.fetch(second.id)

    assert Oidc::SessionGeneration.ready?
    assert_not Session.exists?(third.id)
    assert_disconnect_broadcast channels.fetch(third.id)
  end

  test "steady-state session validation issues only read queries" do
    session = federated_session("read-only-generation-session")
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      statements << payload[:sql]
    end

    assert session.valid_for_authentication?

    assert_not_empty statements
    assert statements.all? { _1.lstrip.match?(/\ASELECT\b/i) }, statements.inspect
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "steady-state validation succeeds while another connection holds the writer lock" do
    session = federated_session("writer-contention-session")
    locked = Queue.new
    release = Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Account.transaction do
          Account.where(id: accounts(:signal).id)
            .update_all("oidc_session_generation = oidc_session_generation")
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    connection = ActiveRecord::Base.connection
    original_busy_timeout = connection.select_value("PRAGMA busy_timeout").to_i
    connection.execute("PRAGMA busy_timeout = 0")

    assert session.valid_for_authentication?
  ensure
    connection&.execute("PRAGMA busy_timeout = #{original_busy_timeout}") if original_busy_timeout
    release << true if writer&.alive?
    writer&.join(2)
  end

  private
    def federated_session(sid)
      users(:jz).sessions.start!(
        user_agent: "Browser", ip_address: "192.0.2.1", identity: @identity,
        oidc_session_id: sid, oidc_issued_at: Time.current.to_i
      )
    end

    def internal_channel(session)
      ActionCable.server.remote_connections.where(
        current_user: session.user, current_session_id: session.id
      ).send(:internal_channel)
    end

    def broadcasts(channel)
      ActionCable.server.pubsub.broadcasts(channel)
    end

    def assert_disconnect_broadcast(channel)
      payload = ActiveSupport::JSON.decode(broadcasts(channel).sole)
      assert_equal({
        "type" => "disconnect", "reason" => Session::REVOKED_REASON, "reconnect" => false
      }, payload)
    end

    def cleanup_records
      identity = Identity.find_by(issuer: Oidc.issuer, subject: SUBJECT)
      Session.where(identity:).destroy_all if identity
      identity&.delete
      Oidc::Revocation.delete_all
    end
end
