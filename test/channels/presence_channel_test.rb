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

  test "subscribing to a direct room updates direct room entries for all room members" do
    room = rooms(:david_and_jason)
    jason_rooms_stream = Turbo::StreamsChannel.send(:stream_name_from, [ users(:jason), :rooms ])

    assert_broadcasts jason_rooms_stream, 1 do
      subscribe room_id: room.id
    end
  end

  test "subscribing to any room updates direct room entries for direct chat members" do
    room = rooms(:designers)
    jason_rooms_stream = Turbo::StreamsChannel.send(:stream_name_from, [ users(:jason), :rooms ])
    kevin_rooms_stream = Turbo::StreamsChannel.send(:stream_name_from, [ users(:kevin), :rooms ])

    assert_broadcasts jason_rooms_stream, 1 do
      assert_broadcasts kevin_rooms_stream, 1 do
        subscribe room_id: room.id
      end
    end
  end
end
