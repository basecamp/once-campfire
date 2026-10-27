require "application_system_test_case"

class MessageMenuTest < ApplicationSystemTestCase
  setup do
    sign_in "kevin@37signals.com"
  end

  test "quick boosting a message from its menu" do
    join_room rooms(:designers)

    within_message messages(:third) do
      reveal_message_actions
      click_on "Thumbs up"

      assert_selector ".boost", text: "👍"
    end
  end

  test "a message gets its menu when it is first opened, and only then" do
    message = messages(:third)
    join_room message.room

    within_message message do
      assert_no_selector ".message__actions-menu", visible: :all

      reveal_message_actions
      assert_selector ".message__actions-menu[style*='--max-width']"

      find(".message__options-btn").click
      assert_no_selector ".message__boost-btn"
      reveal_message_actions

      assert_selector ".message__actions-menu", count: 1
      assert_selector "[aria-label='Copy link'][data-copy-to-clipboard-content-value$='#{room_at_message_path(message.room, message)}']"
    end
  end

  # Only the room page carries the menu the messages copy. Search results hide a message's actions, and a
  # message opened on its own is the source of its edit frame, never formatted into view.
  test "a message's menu is out of reach on the pages that don't carry the room's" do
    message = rooms(:designers).messages.create! body: "A needle in the haystack", client_message_id: "needle", creator: users(:jz)

    visit searches_url(q: "needle")
    assert_selector "#search-results .message", text: "A needle in the haystack"
    assert_selector "#search-results .message__actions", visible: :hidden

    visit room_message_url(message.room, message)
    assert_selector "##{dom_id(message)} .message__actions", visible: :hidden
  end

  test "a message with a file opens the menu it came with" do
    message = rooms(:designers).messages.create_with_attachment! creator: users(:jz), client_message_id: "moon",
      attachment: { io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg" }
    join_room message.room

    within_message message do
      reveal_message_actions

      assert_selector ".message__actions-menu", count: 1
      assert_selector "[aria-label='Download']"
      assert_no_selector "[aria-label='Reply']"
    end
  end
end
