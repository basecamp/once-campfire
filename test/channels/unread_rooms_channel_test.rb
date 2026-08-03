require "test_helper"

class UnreadRoomsChannelTest < ActionCable::Channel::TestCase
  setup do
    stub_connection(current_user: users(:david))
  end

  test "subscribes only to the current user's unread stream" do
    subscribe

    assert subscription.confirmed?
    assert_has_stream_for users(:david)
  end

  test "a removed member receives no future room activity" do
    room = rooms(:designers)
    removed_user = users(:kevin)
    Membership.find_by!(room:, user: removed_user).destroy!
    message = room.messages.create!(
      creator: users(:david), body: "Private after removal", client_message_id: SecureRandom.uuid
    )

    assert_no_broadcasts UnreadRoomsChannel.broadcasting_for(removed_user) do
      assert_broadcasts UnreadRoomsChannel.broadcasting_for(users(:jz)), 1 do
        message.broadcast_create
      end
    end
  end
end
