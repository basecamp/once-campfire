require "test_helper"

class Messages::BotActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:david)
    @room = rooms(:watercooler)
    @message = @room.messages.create!(creator: users(:bender), body: "Deploy?", bot_actions: [
      { label: "Deploy", value: "deploy:a1b2c3", style: "primary" }
    ])
    SecureRandom.stubs(:uuid).returns("event-123")
    sign_in @user
  end

  test "clicking an action schedules its bot callback" do
    assert_enqueued_with job: Bot::ActionWebhookJob, args: [ users(:bender), @message, @user, "deploy:a1b2c3", false, { event_id: "event-123" } ] do
      post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
    end

    assert_response :accepted
  end

  test "single selections persist and toggle" do
    @message.update! bot_action_selection_mode: "single"

    assert_enqueued_with job: Bot::ActionWebhookJob, args: [ users(:bender), @message, @user, "deploy:a1b2c3", true, { event_id: "event-123" } ] do
      post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
    end

    get room_bot_action_selections_url(@room), params: { message_ids: [ @message.id ] }
    assert_equal [ "deploy:a1b2c3" ], response.parsed_body[@message.id.to_s]

    assert_enqueued_with job: Bot::ActionWebhookJob, args: [ users(:bender), @message, @user, "deploy:a1b2c3", false, { event_id: "event-123" } ] do
      post room_message_bot_actions_url(@room, @message), params: { value: "deploy:a1b2c3" }
    end

    get room_bot_action_selections_url(@room), params: { message_ids: [ @message.id ] }
    assert_empty response.parsed_body[@message.id.to_s]
  end

  test "multiple selections persist independently" do
    @message.update! bot_action_selection_mode: "multiple", bot_actions: [
      { label: "Tests", value: "check:tests" },
      { label: "Docs", value: "check:docs" }
    ]

    post room_message_bot_actions_url(@room, @message), params: { value: "check:tests" }
    post room_message_bot_actions_url(@room, @message), params: { value: "check:docs" }

    get room_bot_action_selections_url(@room), params: { message_ids: [ @message.id ] }
    assert_equal %w[ check:tests check:docs ], response.parsed_body[@message.id.to_s]
  end

  test "selection restoration batches messages and only returns messages in the room" do
    second_message = @room.messages.create!(creator: users(:bender), body: "Dessert?", bot_action_selection_mode: "single", bot_actions: [
      { label: "Cake", value: "dessert:cake" }
    ])
    other_message = rooms(:designers).messages.create!(creator: users(:bender), body: "Secret?", bot_action_selection_mode: "single", bot_actions: [
      { label: "Yes", value: "secret:yes" }
    ])
    @message.update! bot_action_selection_mode: "single"
    @message.bot_action_selections.create! user: @user, values: [ "deploy:a1b2c3" ]
    second_message.bot_action_selections.create! user: @user, values: [ "dessert:cake" ]

    get room_bot_action_selections_url(@room), params: { message_ids: [ @message.id, second_message.id, other_message.id ] }

    assert_equal [ "deploy:a1b2c3" ], response.parsed_body[@message.id.to_s]
    assert_equal [ "dessert:cake" ], response.parsed_body[second_message.id.to_s]
    assert_nil response.parsed_body[other_message.id.to_s]
  end

  test "changing action values or selection mode clears selections" do
    @message.update! bot_action_selection_mode: "multiple", bot_actions: [
      { label: "Tests", value: "check:tests" },
      { label: "Docs", value: "check:docs" }
    ]
    @message.bot_action_selections.create! user: @user, values: %w[ check:tests check:docs ]

    @message.update! bot_action_selection_mode: "single"
    assert_empty @message.bot_action_selections

    @message.bot_action_selections.create! user: @user, values: [ "check:tests" ]
    @message.update! bot_actions: [ { label: "Docs", value: "check:docs" } ]
    assert_empty @message.bot_action_selections
  end

  test "selection cleanup rolls back with its message update" do
    @message.update! bot_action_selection_mode: "single"
    selection = @message.bot_action_selections.create! user: @user, values: [ "deploy:a1b2c3" ]

    assert_raises RuntimeError do
      Message.transaction do
        @message.update! bot_actions: [ { label: "Cancel", value: "cancel" } ]
        raise "rollback"
      end
    end

    assert_equal [ "deploy:a1b2c3" ], selection.reload.values
  end

  test "changing action appearance preserves selections" do
    @message.update! bot_action_selection_mode: "single"
    selection = @message.bot_action_selections.create! user: @user, values: [ "deploy:a1b2c3" ]

    @message.update! bot_actions: [ { label: "Deploy now", value: "deploy:a1b2c3", style: "danger" } ]

    assert_equal [ "deploy:a1b2c3" ], selection.reload.values
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

  test "an action cannot be triggered after its bot webhook is removed" do
    users(:bender).webhook.destroy!

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
