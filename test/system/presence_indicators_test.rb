require "application_system_test_case"

class PresenceIndicatorsTest < ApplicationSystemTestCase
  test "shows online status in direct chats" do
    room = rooms(:david_and_jason)

    sign_in "david@37signals.com"
    join_room room

    assert_selector "##{dom_id(room, :list)} .avatar--offline", wait: 5

    using_session("Jason") do
      sign_in "jason@37signals.com"
      join_room room
    end

    assert_selector "##{dom_id(room, :list)} .avatar--online", wait: 5
  end

  test "shows direct chat users online when they are active in another room" do
    direct_room = rooms(:david_and_jason)

    sign_in "david@37signals.com"
    join_room direct_room
    assert_selector "##{dom_id(direct_room, :list)} .avatar--offline", wait: 5

    using_session("Jason") do
      sign_in "jason@37signals.com"
      join_room rooms(:designers)
      fill_in_rich_text_area "message_body", with: "I am active here"
    end

    assert_selector "##{dom_id(direct_room, :list)} .avatar--online", wait: 5
  end

  test "shows typing indicator message" do
    room = rooms(:designers)

    sign_in "jz@37signals.com"
    join_room room

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room room
      fill_in_rich_text_area "message_body", with: "Drafting a response"
    end

    assert_selector "[data-typing-notifications-target='author']", text: "Kevin is typing...", wait: 5
  end
end
