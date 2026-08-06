require "test_helper"

class Rooms::ClosedsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show redirects to get general show" do
    get rooms_open_url(users(:david).rooms.closeds.last)
    assert_redirected_to room_url(users(:david).rooms.closeds.last)
  end

  test "new" do
    get new_rooms_closed_url
    assert_response :success
  end

  test "create" do
    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
    assert_turbo_stream_broadcasts [ users(:kevin), :rooms ], count: 1 do
    assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
      post rooms_closeds_url, params: { room: { name: "My New Room" }, user_ids: [ users(:david).id, users(:kevin).id, users(:jason).id ] }
    end
    end
    end

    new_room = Room.last
    assert_equal new_room.memberships.count, 3
    assert_redirected_to room_url(Room.last)
  end

  test "create forbidden by non-admin when account restricts creation to admins" do
    accounts(:signal).settings.restrict_room_creation_to_administrators = true
    accounts(:signal).save!

    sign_in :jz
    post rooms_closeds_url, params: { room: { name: "My New Room" }, user_ids: [ users(:david).id, users(:kevin).id, users(:jason).id ] }
    assert_response :forbidden
  end


  test "update with membership revisions" do
    assert_difference -> { rooms(:designers).reload.users.count }, -1 do
      put rooms_closed_url(rooms(:designers)), params: {
        room: { name: "New Name" }, user_ids: rooms(:designers).users.without(users(:jason)).collect(&:id)
      }
    end

    assert_redirected_to room_url(rooms(:designers))
    assert rooms(:designers).reload.name, "New Name"
  end

  test "update an open room to be closed" do
    put rooms_closed_url(rooms(:pets)), params: { room: { name: "Doesn't matter" }, user_ids: [ users(:david).id, users(:jason).id ] }
    assert_equal rooms(:pets).memberships.count, 2
  end

  test "cannot update a direct room or its participants as closed" do
    room = rooms(:david_and_jason)
    participant_ids = room.user_ids.sort

    put rooms_closed_url(room), params: {
      room: { name: "Not closed" }, user_ids: [ users(:david).id ]
    }

    assert_redirected_to root_url
    assert room.reload.direct?
    assert_equal participant_ids, room.user_ids.sort
  end

  test "only admins or creators can update" do
    sign_in :jz

    assert_turbo_stream_broadcasts :rooms, count: 0 do
      put rooms_closed_url(rooms(:designers)), params: { room: { name: "New Name" } }
    end

    assert_response :forbidden
    assert rooms(:designers).reload.name, "Designers"
  end

  test "a direct room can't be converted to closed and have its participants revised" do
    sign_in :kevin
    direct = rooms(:bender_and_kevin)

    put rooms_closed_url(direct), params: {
      room: { name: "Watercooler" }, user_ids: [ users(:kevin).id, users(:jz).id ]
    }

    assert_redirected_to root_url
    assert_equal "Rooms::Direct", Room.find(direct.id).type
    assert_equal [ users(:bender).id, users(:kevin).id ].sort, Room.find(direct.id).user_ids.sort
  end

  test "remove yourself" do
    assert_difference -> { users(:david).rooms.count }, -1 do
      put rooms_closed_url(rooms(:designers), params: { room: { name: "Designers" }, user_ids: [ users(:jason).id, users(:jz).id ] })

      assert_redirected_to room_url(rooms(:designers))
      follow_redirect!
      assert_redirected_to root_url
    end
  end
end
