require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "user does not prevent very long passwords" do
    users(:david).update(password: "secret" * 50)
    assert users(:david).valid?
  end

  test "creating users grants membership to the open rooms" do
    assert_difference -> { Membership.count }, +Rooms::Open.count do
      create_new_user
    end
  end

  test "memberships granted to the open rooms are like any other" do
    freeze_time
    user = create_new_user

    assert_equal Rooms::Open.ids.sort, user.memberships.pluck(:room_id).sort
    user.memberships.each do |membership|
      assert membership.involved_in_mentions?
      assert_equal Time.current, membership.created_at
      assert_equal Time.current, membership.updated_at
    end
  end

  test "deactivating a user deletes push subscriptions, searches, memberships for non-direct rooms, and changes their email address" do
    assert_difference -> { Membership.count }, -users(:david).memberships.without_direct_rooms.count do
    assert_difference -> { Push::Subscription.count }, -users(:david).push_subscriptions.count do
    assert_difference -> { Search.count }, -users(:david).searches.count do
      SecureRandom.stubs(:uuid).returns("2e7de450-cf04-4fa8-9b02-ff5ab2d733e7")
      users(:david).deactivate
      assert_equal "david-deactivated-2e7de450-cf04-4fa8-9b02-ff5ab2d733e7@37signals.com", users(:david).reload.email_address
    end
    end
    end
  end

  test "deactivating a user deletes their sessions" do
    assert_changes -> { users(:david).sessions.count }, from: 1, to: 0 do
      users(:david).deactivate
    end
  end

  test "changing the password signs out every session, the current one included" do
    Current.session = users(:david).sessions.start!(user_agent: "This device", ip_address: "127.0.0.1")

    assert_changes -> { users(:david).sessions.count }, to: 0 do
      users(:david).update!(password: "a new secret123456")
    end
  end

  test "changing the password closes the account's live connections" do
    remote_connections = mock
    remote_connections.expects(:disconnect).with(reconnect: true)
    ActionCable.server.stubs(:remote_connections).returns(mock.tap { |m| m.expects(:where).with(current_user: users(:david)).returns(remote_connections) })

    users(:david).update!(password: "a new secret123456")
  end

  test "changing the password closes live connections even when the user is saved again before commit" do
    remote_connections = mock
    remote_connections.expects(:disconnect).with(reconnect: true)
    ActionCable.server.stubs(:remote_connections).returns(mock.tap { |m| m.expects(:where).with(current_user: users(:david)).returns(remote_connections) })

    User.transaction do
      users(:david).update!(password: "a new secret123456")
      users(:david).update!(name: "Dave")
    end
  end

  test "a password change that rolls back keeps every session and connection" do
    ActionCable.server.expects(:remote_connections).never

    assert_no_changes -> { users(:david).sessions.count } do
      User.transaction do
        users(:david).update!(password: "a new secret123456")
        raise ActiveRecord::Rollback
      end
    end
  end

  test "changing the password removes every push subscription of the user" do
    assert users(:david).push_subscriptions.any?

    users(:david).update!(password: "a new secret123456")

    assert_empty users(:david).push_subscriptions.reload
    assert users(:jason).push_subscriptions.any?
  end

  test "a password change that rolls back keeps push subscriptions" do
    assert_no_changes -> { users(:david).push_subscriptions.count } do
      User.transaction do
        users(:david).update!(password: "a new secret123456")
        raise ActiveRecord::Rollback
      end
    end
  end

  test "changing other details keeps every session" do
    ActionCable.server.expects(:remote_connections).never

    assert_no_changes -> { [ users(:david).sessions.count, users(:david).push_subscriptions.count ] } do
      users(:david).update!(name: "Dave", email_address: "dave@37signals.com")
    end
  end

  private
    def create_new_user
      User.create!(name: "User", email_address: "user@example.com", password: "secret123456")
    end
end
