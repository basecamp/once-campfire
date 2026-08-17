require "application_system_test_case"

class BotActionsTest < ApplicationSystemTestCase
  setup do
    @room = rooms(:watercooler)
    @message = @room.messages.create!(creator: users(:bender), body: "Lunch?", bot_action_selection_mode: "single", bot_actions: [
      { label: "Pizza", value: "lunch:pizza", emoji: "🍕" },
      { label: "Sushi", value: "lunch:sushi", emoji: "🍣" }
    ])

    sign_in "david@37signals.com"
    join_room @room
  end

  test "selecting, restoring, and deselecting an action" do
    within_message @message do
      click_on "Pizza"
      assert_selector "button[aria-pressed='true']", text: "Pizza"
    end

    refresh

    within_message @message do
      assert_selector "button[aria-pressed='true']", text: "Pizza"
      click_on "Pizza"
      assert_selector "button[aria-pressed='false']", text: "Pizza"
    end
  end

  test "showing feedback when an action is rejected" do
    within_message @message do
      assert_selector "button[aria-pressed='false']", text: "Pizza"
      users(:bender).webhook.destroy!

      click_on "Pizza"

      assert_text "Couldn’t perform that action."
      assert_selector "button[aria-pressed='false']", text: "Pizza"
    end
  end

  test "disabling value actions when the webhook has been removed" do
    users(:bender).webhook.destroy!
    refresh

    within_message @message do
      assert_selector "button:disabled", text: "Pizza"
      assert_selector "button:disabled", text: "Sushi"
    end
  end
end
