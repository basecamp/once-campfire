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

  test "actions without a selection mode never gain a pressed state" do
    @message.update! bot_action_selection_mode: "none"
    refresh

    within_message @message do
      assert_no_selector "button[aria-pressed]"

      users(:bender).webhook.destroy!
      click_on "Pizza"

      assert_text "Couldn’t perform that action."
      assert_no_selector "button[aria-pressed]"
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

  test "selecting multiple checklist actions and restoring them" do
    @message.update! bot_action_selection_mode: "multiple", bot_actions: [
      { label: "Tests", value: "check:tests", icon: "check" },
      { label: "Docs", value: "check:docs", emoji: "📚" }
    ]
    refresh

    within_message @message do
      click_on "Tests"
      click_on "Docs"
      assert_selector "button[aria-pressed='true']", text: "Tests"
      assert_selector "button[aria-pressed='true']", text: "Docs"
    end

    refresh

    within_message @message do
      assert_selector "button[aria-pressed='true']", count: 2
    end
  end

  test "rendering link, icon-only, and disabled actions accessibly" do
    @message.update! bot_actions: [
      { label: "Open runbook", url: "https://example.com/runbook", icon: "link" },
      { label: "Open camera", url: "homeassistant://navigate/dashboard", emoji: "📷", icon_only: true },
      { label: "Voting closed", url: "https://example.com/vote", disabled: true }
    ]
    refresh

    within_message @message do
      assert_selector "a[href='https://example.com/runbook'][target='_blank']", text: "Open runbook"
      assert_selector "a.message__bot-action--icon-only[title='Open camera'][href='homeassistant://navigate/dashboard']"
      assert_selector "span[aria-disabled='true']", text: "Voting closed"
    end
  end
end
