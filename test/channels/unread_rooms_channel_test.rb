require "test_helper"

class UnreadRoomsChannelTest < ActionCable::Channel::TestCase
  setup do
    stub_connection(current_user: users(:david))
  end

  test "subscribes only to the current user's unread stream" do
    subscribe

    assert subscription.confirmed?
    assert_has_stream_for users(:david)
    assert_not_includes subscription.streams, UnreadRoomsChannel.broadcasting_for(users(:jz))
    assert_not_includes subscription.streams, "unread_rooms"
  end

  test "an outsider is not told about activity in a room they cannot see" do
    room = rooms(:bender_and_kevin)
    outsider = users(:jz)
    assert_not room.users.include?(outsider), "jz must be an outsider for this test to mean anything"

    assert_no_broadcasts UnreadRoomsChannel.broadcasting_for(outsider) do
      room.messages.create!(
        body: "Private", creator: users(:kevin), client_message_id: SecureRandom.uuid
      )
    end
  end

  test "a member is told about activity in their own room" do
    room = rooms(:bender_and_kevin)
    recipient = users(:kevin)

    assert_broadcasts UnreadRoomsChannel.broadcasting_for(recipient), 1 do
      room.messages.create!(
        body: "Private", creator: users(:bender), client_message_id: SecureRandom.uuid
      )
    end
  end

  test "a removed member receives no future room activity" do
    room = rooms(:designers)
    removed_user = users(:kevin)
    Membership.find_by!(room:, user: removed_user).destroy!

    assert_no_broadcasts UnreadRoomsChannel.broadcasting_for(removed_user) do
      assert_broadcasts UnreadRoomsChannel.broadcasting_for(users(:jz)), 1 do
        room.messages.create!(
          creator: users(:david), body: "Private after removal", client_message_id: SecureRandom.uuid
        )
      end
    end
  end

  test "the room broadcast does not query or fan out over participants" do
    message = messages(:first)
    message.room
    message.stubs(:broadcast_append_to)

    UnreadRoomsChannel.expects(:broadcast_to).never
    assert_no_queries { message.broadcast_create }
  end
end
