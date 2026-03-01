require "test_helper"

class Users::SidebarsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show" do
    get user_sidebar_url

    users(:david).rooms.opens.each do |room|
      assert_match /#{room.name}/, @response.body
    end
  end

  test "unread directs" do
    rooms(:david_and_jason).messages.create! client_message_id: 999, body: "Hello", creator: users(:jason)

    get user_sidebar_url
    assert_select ".unread", count: users(:david).memberships.select { |m| m.room.direct? && m.unread? }.count
  end


  test "unread other" do
    rooms(:watercooler).messages.create! client_message_id: 999, body: "Hello", creator: users(:jason)

    get user_sidebar_url
    assert_select ".unread", count: users(:david).memberships.reject { |m| m.room.direct? || !m.unread? }.count
  end

  test "hides direct rooms with deactivated users" do
    direct_room = Rooms::Direct.create!(creator: users(:david))
    direct_room.memberships.grant_to([ users(:david), users(:bender) ])

    get user_sidebar_url
    assert_select "a[href='#{room_path(direct_room)}']", count: 1

    users(:bender).deactivate

    get user_sidebar_url
    assert_select "a[href='#{room_path(direct_room)}']", count: 0
  end
end
