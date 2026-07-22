require "test_helper"

class Messages::Boosts::ByBotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @message = messages(:fourth)  # Message in watercooler room where bender bot is a member
    @bot = users(:bender)
  end

  test "create adds a boost to the message" do
    assert_difference -> { @message.boosts.count }, +1 do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"👀"
      assert_response :created
    end

    assert_equal "👀", @message.boosts.last.content
  end

  test "create with emoji reaction" do
    assert_difference -> { Boost.count }, +1 do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"🎉"
      assert_response :created
    end
  end

  test "create with text reaction" do
    assert_difference -> { Boost.count }, +1 do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"Nice!"
      assert_response :created
    end

    assert_equal "Nice!", @message.boosts.last.content
  end

  test "create broadcasts the boost" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"👍"
    end
  end

  test "create requires valid bot key" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, "invalid-bot-key", @message), params: +"👀"
    end
    assert_response :redirect  # Redirects to login
  end

  test "create returns not_found for room bot is not a member of" do
    room_without_bot = rooms(:designers)
    message_in_other_room = messages(:first)  # Message in designers room

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(room_without_bot, @bot.bot_key, message_in_other_room), params: +"👀"
    end
    assert_response :not_found
  end

  test "create returns not_found for message not in the room" do
    message_in_other_room = messages(:first)  # Message in designers room, not watercooler

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, message_in_other_room), params: +"👀"
    end
    assert_response :not_found
  end

  test "create can't be abused to post boosts as regular user" do
    user = users(:kevin)
    bot_key = "#{user.id}-"

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, bot_key, @message), params: +"👀"
    end
    assert_response :redirect
  end
end
