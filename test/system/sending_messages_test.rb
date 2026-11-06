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

  test "a message on its way shows the text as it was typed" do
    text = %(sed 's/a/$&/' and echo $'b' and $$ and $` and $messageTimestamp$ end)
    # The template carries the author's name, which can look like a placeholder too, or like an object's own method.
    users(:jz).update!(name: "J$Z$ $constructor$")
    join_room rooms(:designers)
    messages_before = all(".message", visible: :all).size

    # The server holds the message longer than the wait below, so the page shows it pending meanwhile.
    Message.define_singleton_method(:create_with_attachment!) { |attributes| sleep 3; super(attributes) }
    type_in_composer text
    click_on "send"

    assert_selector "[data-pending-message] .lexxy-content", exact_text: text
    assert_selector "[data-pending-message] .message__author", exact_text: "J$Z$ $constructor$"
    assert_equal messages_before + 1, all(".message", visible: :all).size

    assert_selector ".message[data-message-id]:not([data-pending-message]) .lexxy-content", exact_text: text, wait: 10
    assert_no_selector "[data-pending-message]", visible: :all
  ensure
    Message.singleton_class.remove_method(:create_with_attachment!)
  end

  test "a message that can't be sent keeps the text as it was typed" do
    text = %(sed 's/a/$&/' and echo $'b' and $$ and $` and $messageTimestamp$ end)

    page.driver.browser.network_conditions = { offline: true, latency: 0, throughput: 0 }
    type_in_composer text
    click_on "send"

    assert_selector ".message--failed .lexxy-content", exact_text: text
  ensure
    page.driver.browser.delete_network_conditions
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
