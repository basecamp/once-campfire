require "test_helper"

class UnreadRoomsChannelTest < ActionCable::Channel::TestCase
  test "streams only the subscriber's own unread stream" do
    stub_connection(current_user: users(:jz))

    subscribe

    assert subscription.confirmed?
    assert_has_stream "user_#{users(:jz).id}_unreads"
    assert_not_includes subscription.streams, "unread_rooms"
  end

  test "an outsider is not told about activity in a room they can't see" do
    direct = rooms(:bender_and_kevin)
    assert_not direct.users.include?(users(:jz)), "jz must be an outsider for this test to mean anything"

    broadcasts = capture_unread_broadcasts_for(users(:jz)) do
      perform_enqueued_jobs only: Message::BroadcastUnreadRoomJob do
        direct.messages.create!(body: "Private", creator: users(:kevin), client_message_id: "outsider").broadcast_create
      end
    end

    assert_empty broadcasts
  end

  test "a member is told about activity in their own room" do
    direct = rooms(:bender_and_kevin)

    broadcasts = capture_unread_broadcasts_for(users(:kevin)) do
      perform_enqueued_jobs only: Message::BroadcastUnreadRoomJob do
        direct.messages.create!(body: "Private", creator: users(:bender), client_message_id: "member").broadcast_create
      end
    end

    assert_equal [ direct.id ], broadcasts.collect { |broadcast| broadcast["roomId"] }
  end

  private
    def capture_unread_broadcasts_for(user)
      stub_connection(current_user: user)
      subscribe

      stream = subscription.streams.sole
      before = ActionCable.server.pubsub.broadcasts(stream).size

      yield

      ActionCable.server.pubsub.broadcasts(stream).drop(before).collect { |broadcast| JSON.parse(broadcast) }
    end
end
