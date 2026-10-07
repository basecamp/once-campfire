require "application_system_test_case"

class UnreadRoomsTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
  end

  test "sending messages between two users" do
    designers_room = rooms(:designers)
    hq_room = rooms(:hq)

    join_room hq_room
    assert_room_read hq_room

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room designers_room

      perform_enqueued_jobs only: Message::BroadcastUnreadRoomJob do
        send_message("Hello!!")
        send_message("Talking to myself?")
      end
    end

    assert_room_unread designers_room

    join_room designers_room
    assert_room_read designers_room
  end

  test "a notice about a message from before the room was read in another tab doesn't mark it unread again" do
    using_session("Kevin in HQ") do
      sign_in "kevin@37signals.com"
      join_room rooms(:hq)
      broadcast_unread_notice rooms(:designers), to: users(:kevin), at: Time.current
      assert_room_unread rooms(:designers)
    end

    sent_before_reading = Time.current
    using_session("Kevin in Designers") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
    end

    using_session("Kevin in HQ") do
      assert_room_read rooms(:designers)

      broadcast_unread_notice rooms(:designers), to: users(:kevin), at: sent_before_reading
      broadcast_unread_notice rooms(:bender_and_kevin), to: users(:kevin), at: Time.current
      assert_selector "#" + dom_id(rooms(:bender_and_kevin), :list) + ".unread"
      assert_room_read rooms(:designers)

      broadcast_unread_notice rooms(:designers), to: users(:kevin), at: Time.current
      assert_room_unread rooms(:designers)
    end
  end

  private
    def broadcast_unread_notice(room, to:, at:)
      ActionCable.server.broadcast UnreadRoomsChannel.stream_name_for(to.id), { roomId: room.id, at: at.to_fs(:epoch) }
    end
end
