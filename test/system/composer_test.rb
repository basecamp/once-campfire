require "application_system_test_case"

class ComposerTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  test "enter sends the message when the toolbar is collapsed" do
    type_in_composer "A quick reply"
    press_in_composer :enter

    assert_message_text "A quick reply"
    assert_composer_empty
  end

  test "enter adds a newline in rich text mode and meta+enter sends" do
    toggle_rich_text_toolbar

    type_in_composer "line one"
    press_in_composer :enter
    type_in_composer "line two"

    assert_no_message_text "line one"

    press_in_composer [ :control, :enter ]

    assert_message_text /line one\s*line two/
    assert_composer_empty
  end

  test "markdown strikethrough survives sanitization" do
    type_in_composer "Hello ~~Claude~~ World"
    press_in_composer :enter

    assert_selector last_message_selector("s"), text: "Claude"
    assert_message_text "Hello Claude World"
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

  test "replying quotes the original message with attribution" do
    within_message messages(:third) do
      reveal_message_actions
      find("[aria-label='Reply']").click
    end

    assert_composer_text "Third time's a charm."

    click_send_button

    assert_selector last_message_selector("blockquote"), text: "Third time's a charm."
    assert_selector last_message_selector("cite"), text: "JZ"
  end

  test "arrow up edits my last message when the composer is empty" do
    composer_editor.click
    press_in_composer :up

    assert_selector ".message__body-content--editing"
    assert_edit_editor_text "Third time's a charm."
  end

  test "pasting a URL unfurls an opengraph preview" do
    metadata = Opengraph::Metadata.new(
      title: "Example Site",
      url: "https://example.com/article",
      description: "An example article",
      image: ""
    )
    Opengraph::Metadata.stubs(:from_url).returns(metadata)

    paste_in_composer "https://example.com/article"

    within "#composer" do
      assert_selector ".og-embed__title", text: "Example Site", wait: 10
    end

    click_send_button

    assert_selector last_message_selector(".og-embed__title"), text: "Example Site"
  end

  private
    def click_send_button
      find("#composer [data-action='composer#submit']").click
    end

    def last_message_selector(inner)
      ".message:last-of-type .message__body #{inner}"
    end

    def assert_no_message_text(text)
      assert_no_selector ".message__body", text: text
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
