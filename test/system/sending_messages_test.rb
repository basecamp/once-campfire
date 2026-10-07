require "application_system_test_case"

class SendingMessagesTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  test "sending messages between two users" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
    end

    join_room rooms(:designers)
    send_message "Is this thing on?"

    # The optimistic pending message is reconciled with the server broadcast even
    # though they no longer share a DOM id: exactly one element, no duplicate.
    assert_selector ".message__body", text: "Is this thing on?", count: 1
    assert_no_selector "[data-pending-message]"

    using_session("Kevin") do
      join_room rooms(:designers)
      assert_message_text "Is this thing on?"

      send_message "👍👍"
    end

    join_room rooms(:designers)
    assert_message_text "👍👍"
  end

  test "editing messages" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)
    end

    within_message messages(:third) do
      reveal_message_actions
      find(".message__edit-btn").click
      fill_in_rich_text_area "message_body", with: "Redacted!"
      click_on "Save changes"
    end

    using_session("Kevin") do
      join_room rooms(:designers)

      assert_message_text "Redacted!"
    end
  end

  test "deleting messages" do
    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room rooms(:designers)

      assert_message_text "Third time's a charm."
    end

    within_message messages(:third) do
      reveal_message_actions
      find(".message__edit-btn").click

      accept_confirm do
        click_on "Delete message"
      end
    end

    using_session("Kevin") do
      assert_message_text "Third time's a charm.", count: 0
    end
  end
end
