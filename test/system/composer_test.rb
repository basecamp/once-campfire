require "application_system_test_case"

class ComposerTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  test "mentioning a user with @ inserts a mention attachment" do
    type_in_composer "Hey @Jas"
    pick_mention "Jason"
    click_send_button

    assert_selector last_message_selector(".mention"), text: "Jason"

    message = wait_for_persisted_message
    assert_includes message.body.body.to_html, "application/vnd.campfire.mention"
    assert_equal [ users(:jason) ], message.mentionees
  end

  test "editing a message with a mention keeps the mention" do
    type_in_composer "Hey @Jas"
    pick_mention "Jason"
    click_send_button

    assert_selector last_message_selector(".mention"), text: "Jason"
    message = wait_for_persisted_message

    within_message message do
      reveal_message_actions
      find(".message__edit-btn").click
      assert_edit_editor_text "Jason"
      click_on "Save changes"
    end

    assert_selector last_message_selector(".mention"), text: "Jason"
    assert_equal [ users(:jason) ], message.reload.mentionees
  end

  private
    def click_send_button
      find("#composer [data-action='composer#submit']").click
    end

    def last_message_selector(inner)
      ".message:last-of-type .message__body #{inner}"
    end

    # The message insert races with the form POST, so give the server a moment
    def wait_for_persisted_message(room: rooms(:designers), since: 1.minute.ago)
      message = nil
      20.times do
        message = room.messages.ordered.last
        break if message.created_at > since
        sleep 0.25
      end
      message
    end
end
