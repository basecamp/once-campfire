require "test_helper"

class Messages::Boosts::ByBotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @message = messages(:fourth)
    @bot = users(:bender)
  end

  test "create adds a boost to the message and returns it" do
    assert_difference -> { @message.boosts.count }, +1 do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"👀"
      assert_response :created
    end

    boost = @message.boosts.last
    assert_equal "👀", boost.content
    assert_equal @bot, boost.booster

    json = JSON.parse(response.body)
    assert_equal boost.id, json["id"]
    assert_equal "👀", json["content"]
    assert_equal @bot.id, json["booster"]["id"]
    assert_equal @message.id, json["message"]["id"]
    assert_equal room_message_url(@room, @message), json["message"]["url"]
  end

  test "create with text content" do
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

  test "create without content" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message)
      assert_response :unprocessable_content

      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"   "
      assert_response :unprocessable_content
    end
  end

  test "create requires a valid bot key" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, "invalid-bot-key", @message), params: +"👀"
    end
    assert_response :redirect
  end

  test "create is not found for a room the bot is not a member of" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(rooms(:designers), @bot.bot_key, messages(:first)), params: +"👀"
    end
    assert_response :not_found
  end

  test "create is not found for a message outside the room" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, messages(:first)), params: +"👀"
    end
    assert_response :not_found
  end

  test "create can't be abused to post boosts as a regular user" do
    bot_key = "#{users(:kevin).id}-"

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, bot_key, @message), params: +"👀"
    end
    assert_response :redirect
  end

  test "destroy removes the bot's own boost" do
    assert_difference -> { Boost.count }, -1 do
      delete room_bot_message_boost_url(@room, @bot.bot_key, @message, boosts(:fourth_by_bender))
    end

    assert_response :no_content
  end

  test "destroy broadcasts the removal" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      delete room_bot_message_boost_url(@room, @bot.bot_key, @message, boosts(:fourth_by_bender))
    end
  end

  test "destroy can't touch a boost the bot did not make" do
    assert_no_difference -> { Boost.count } do
      delete room_bot_message_boost_url(@room, @bot.bot_key, messages(:thirteenth), boosts(:thirteenth))
    end

    assert_response :not_found
  end

  test "create rejects content longer than the boost limit" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +("a" * (Boost::MAX_CONTENT_LENGTH + 1))
    end

    assert_response :unprocessable_content
    assert response.parsed_body.dig("errors", "content").present?
  end

  test "destroy requires a valid bot key" do
    assert_no_difference -> { Boost.count } do
      delete room_bot_message_boost_url(@room, "invalid-bot-key", @message, boosts(:fourth_by_bender))
    end

    assert_response :redirect
  end
end
