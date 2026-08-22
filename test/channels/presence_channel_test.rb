require "test_helper"

class PresenceChannelTest < ActionCable::Channel::TestCase
  setup do
    stub_connection(current_user: users(:david))
  end

  test "subscribes" do
    room = users(:david).rooms.first

    subscribe room_id: room.id

    assert subscription.confirmed?
    assert_has_stream_for room
  end

  test "rejects subscription to a room that the user is not a member of" do
    subscribe room_id: Rooms::Closed.create!(name: "New Room", creator: users(:david)).id

    assert subscription.rejected?
  end

  test "rejects subscription to non-existent room" do
    subscribe room_id: -1

    assert subscription.rejected?
  end

  test "rejects subscription without a room" do
    subscribe room_id: -1

    assert subscription.rejected?
  end

  test "subscribing marks the membership as connected" do
    membership = users(:david).memberships.first

    assert_changes -> { membership.reload.connected? }, from: false, to: true do
      subscribe room_id: membership.room_id
    end
  end

  test "unsubscribing marks the membership as disconnected" do
    membership = users(:david).memberships.first
    subscribe room_id: membership.room_id

    assert_changes -> { membership.reload.connected? }, from: true, to: false do
      unsubscribe
    end
  end

  test "rejects a subscription beyond the live presence token cap" do
    membership = users(:david).memberships.first
    Membership::Connectable::MAXIMUM_PRESENCE_TOKENS.times { membership.present }

    subscribe room_id: membership.room_id

    assert subscription.rejected?
    assert_equal Membership::Connectable::MAXIMUM_PRESENCE_TOKENS, membership.reload.presence_tokens.size
  end

  test "refreshing an expired channel presence registers its new generation" do
    membership = users(:david).memberships.first
    subscribe room_id: membership.room_id
    original_generation = membership.reload.presence_generation

    travel Membership::Connectable::CONNECTION_TTL + 1.second do
      perform :refresh

      assert membership.reload.connected?
      assert_equal original_generation + 1, membership.presence_generation
      assert_equal 1, membership.presence_tokens.size
    end

    assert_changes -> { membership.reload.connected? }, from: true, to: false do
      unsubscribe
    end
  end

  test "a live channel replaces its token after another process disconnects all presence" do
    membership = memberships(:david_watercooler)
    subscribe room_id: membership.room_id
    original = subscription.instance_variable_get(:@presence)

    Membership.disconnect_all
    assert_not membership.reload.connected?

    perform :refresh

    replacement = subscription.instance_variable_get(:@presence)
    assert replacement
    assert_not_equal original, replacement
    assert membership.reload.connected?
    assert_equal [ replacement.token ], membership.presence_tokens.keys
    assert_not membership.absent(original)
    assert membership.reload.connected?
  end

  test "a stale channel cannot register presence in a recreated membership" do
    membership = memberships(:david_watercooler)
    subscribe room_id: membership.room_id
    membership.destroy!
    replacement = Membership.create!(room: membership.room, user: membership.user)
    connection.expects(:close).with(reason: "Presence expired", reconnect: true)

    perform :refresh

    assert_empty replacement.reload.presence_tokens
    assert_not replacement.connected?
  end

  test "an expired restart-recovery token forces a reconnect" do
    membership = memberships(:david_watercooler)
    subscribe room_id: membership.room_id
    Membership.disconnect_all
    connection.expects(:close).with(reason: "Presence expired", reconnect: true)

    travel Membership::Connectable::CONNECTION_TTL + 1.second do
      perform :refresh
    end

    assert_empty membership.reload.presence_tokens
    assert_not membership.connected?
    assert_nil subscription.instance_variable_get(:@presence)
  end

  test "rejects a subscription when the membership is at the presence token limit" do
    membership = memberships(:david_watercooler)
    Membership::Connectable::MAXIMUM_PRESENCE_TOKENS.times { membership.present }

    assert_no_difference -> { membership.reload.presence_tokens.size } do
      subscribe room_id: membership.room_id
    end

    assert subscription.rejected?
  end
end
