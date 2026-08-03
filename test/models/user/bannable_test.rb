require "test_helper"

class User::BannableTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class RemoteConnections
    attr_reader :queries

    def initialize
      @queries = []
    end

    def where(**conditions)
      @queries << conditions
      self
    end

    def disconnect(reconnect: false)
      true
    end
  end

  test "a delayed ban disconnect targets only sessions removed by that ban" do
    user = users(:kevin)
    removed_session_ids = user.sessions.ids
    remote_connections = RemoteConnections.new
    ActionCable.server.stubs(:remote_connections).returns(remote_connections)
    new_session = nil

    User.transaction do
      user.ban_by! actor: users(:david)
      user.reload.unban_by! actor: users(:david)
      user.reload
      new_session = user.sessions.start!(user_agent: "New browser", ip_address: "192.0.2.20")

      assert_empty remote_connections.queries
    end

    assert new_session.reload.valid_for_authentication?
    assert_equal removed_session_ids.sort,
      remote_connections.queries.map { _1.fetch(:current_session_id) }.sort
    assert_not_includes remote_connections.queries.map { _1[:current_session_id] }, new_session.id
    assert remote_connections.queries.all? { _1.fetch(:current_user).id == user.id }
  end

  test "authentication loaded before a committed ban cannot create a dormant session" do
    user = users(:kevin)
    authenticated = Queue.new
    continue = Queue.new
    result = Queue.new
    Session.any_instance.stubs(:disconnect_remote_connections)

    login = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        stale_user = User.active.find(user.id)
        authenticated << true
        continue.pop
        stale_user.sessions.start!(user_agent: "Racing browser", ip_address: "192.0.2.30")
        result << :created
      rescue StandardError => error
        result << error
      end
    end
    authenticated.pop

    user.ban_by! actor: users(:david)
    continue << true
    login.join

    assert_kind_of User::AuthorizationError, result.pop
    assert user.reload.banned?
    assert_empty user.sessions
  ensure
    continue << true if login&.alive?
    login&.join(2)
  end
end
