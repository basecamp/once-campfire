require "application_system_test_case"

class UnreadRoomsTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
    wait_for_cable_connection
  end

  test "sending messages between two users" do
    designers_room = rooms(:designers)
    hq_room = rooms(:hq)

    join_room hq_room
    assert_room_read hq_room

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room designers_room
      send_message("Hello!!")
      send_message("Talking to myself?")
    end

    assert_room_unread designers_room

    join_room designers_room
    assert_room_read designers_room
  end
end
