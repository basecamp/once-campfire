require "test_helper"

class Messages::BotActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:david)
    @room = rooms(:watercooler)
    @message = @room.messages.create!(creator: users(:bender), body: "Deploy?", bot_actions: [
      { label: "Deploy", value: "deploy:a1b2c3", style: "primary" }
    ])
    sign_in @user
  end

  test "clicking an action schedules its bot callback" do
    assert_enqueued_with job: Bot::ActionWebhookJob, args: [ users(:bender), @message, @user, "deploy:a1b2c3", false ] do
      post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
    end

    assert_response :accepted
  end

  test "single selections persist and toggle" do
    @message.update! bot_action_selection_mode: "single"

    assert_enqueued_with job: Bot::ActionWebhookJob, args: [ users(:bender), @message, @user, "deploy:a1b2c3", true ] do
      post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
    end

    get selection_room_message_bot_actions_url(@room, @message)
    assert_equal [ "deploy:a1b2c3" ], response.parsed_body["values"]

    assert_enqueued_with job: Bot::ActionWebhookJob, args: [ users(:bender), @message, @user, "deploy:a1b2c3", false ] do
      post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
    end

    get selection_room_message_bot_actions_url(@room, @message)
    assert_empty response.parsed_body["values"]
  end

  test "multiple selections persist independently" do
    @message.update! bot_action_selection_mode: "multiple", bot_actions: [
      { label: "Tests", value: "check:tests" },
      { label: "Docs", value: "check:docs" }
    ]

    post room_message_bot_actions_url(@room, @message), params: { value: "check:tests" }
    post room_message_bot_actions_url(@room, @message), params: { value: "check:docs" }

    get selection_room_message_bot_actions_url(@room, @message)
    assert_equal %w[ check:tests check:docs ], response.parsed_body["values"]
  end

  test "restored selections are normalized after actions and mode change" do
    @message.update! bot_action_selection_mode: "multiple", bot_actions: [
      { label: "Tests", value: "check:tests" },
      { label: "Docs", value: "check:docs" }
    ]
    @message.bot_action_selections.create! user: @user, values: %w[ check:tests check:docs removed ]

    @message.update! bot_action_selection_mode: "single"

    get selection_room_message_bot_actions_url(@room, @message)
    assert_equal [ "check:tests" ], response.parsed_body["values"]

    @message.update! bot_actions: [ { label: "Docs", value: "check:docs" } ]

    get selection_room_message_bot_actions_url(@room, @message)
    assert_equal [ "check:docs" ], response.parsed_body["values"]
  end

  test "an action not currently on the message cannot be triggered" do
    assert_no_enqueued_jobs only: Bot::ActionWebhookJob do
      post room_message_bot_actions_url(@room, @message), params: { value: "delete:everything" }
    end

    assert_response :unprocessable_entity
  end

  test "a disabled action cannot be triggered" do
    @message.update! bot_actions: [ { label: "Deploy", value: "deploy:a1b2c3", disabled: true } ]

    assert_no_enqueued_jobs only: Bot::ActionWebhookJob do
      post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
    end

    assert_response :unprocessable_entity
  end

  test "a user outside the room cannot trigger an action" do
    sign_in :jz

    assert_no_enqueued_jobs only: Bot::ActionWebhookJob do
      assert_raises ActiveRecord::RecordNotFound do
        post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
      end
    end
  end

  test "actions on a human message cannot be triggered" do
    @message.update_columns creator_id: users(:kevin).id

    assert_no_enqueued_jobs only: Bot::ActionWebhookJob do
      post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
    end

    assert_response :unprocessable_entity
  end
end
