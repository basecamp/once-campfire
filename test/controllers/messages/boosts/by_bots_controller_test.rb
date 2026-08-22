require "test_helper"

class Messages::Boosts::ByBotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @message = messages(:fourth)
    @bot = users(:bender)
  end

  test "create adds a boost to the message and returns it" do
    assert_difference -> { @message.boosts.count }, +1 do
      post room_bot_message_boosts_url(@room, @message), params: +"👀", headers: bot_headers
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
      post room_bot_message_boosts_url(@room, @message), params: +"Nice!", headers: bot_headers
      assert_response :created
    end

    assert_equal "Nice!", @message.boosts.last.content
  end

  test "create broadcasts the boost" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      post room_bot_message_boosts_url(@room, @message), params: +"👍", headers: bot_headers
    end
  end

  test "create without content" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @message), headers: bot_headers
      assert_response :unprocessable_content

      post room_bot_message_boosts_url(@room, @message), params: +"   ", headers: bot_headers
      assert_response :unprocessable_content
    end
  end

  test "create rejects oversized content without reading past the limit" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @message),
        params: +("x" * (ContentLimits::MESSAGE_BODY_BYTES + 1)), headers: bot_headers
    end

    assert_response :content_too_large
  end

  test "create requires a valid bot key" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @message),
        params: +"👀", headers: bot_headers("invalid-bot-key")
    end
    assert_response :unauthorized
  end

  test "create rejects an ordinary browser session" do
    sign_in :jz

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @message), params: +"👀"
    end

    assert_response :forbidden
  end

  test "create is not found for a room the bot is not a member of" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(rooms(:designers), messages(:first)),
        params: +"👀", headers: bot_headers
    end
    assert_response :not_found
  end

  test "create is not found for a message outside the room" do
    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, messages(:first)), params: +"👀", headers: bot_headers
    end
    assert_response :not_found
  end

  test "create can't be abused to post boosts as a regular user" do
    bot_key = "#{users(:kevin).id}-"

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @message), params: +"👀", headers: bot_headers(bot_key)
    end
    assert_response :unauthorized
  end

  test "destroy removes the bot's own boost" do
    assert_difference -> { Boost.count }, -1 do
      delete room_bot_message_boost_url(@room, @message, boosts(:fourth_by_bender)), headers: bot_headers
    end

    assert_response :no_content
  end

  test "destroy broadcasts the removal" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      delete room_bot_message_boost_url(@room, @message, boosts(:fourth_by_bender)), headers: bot_headers
    end
  end

  test "destroy can't touch a boost the bot did not make" do
    assert_no_difference -> { Boost.count } do
      delete room_bot_message_boost_url(@room, messages(:thirteenth), boosts(:thirteenth)), headers: bot_headers
    end

    assert_response :not_found
  end

  test "destroy requires a valid bot key" do
    assert_no_difference -> { Boost.count } do
      delete room_bot_message_boost_url(@room, @message, boosts(:fourth_by_bender)),
        headers: bot_headers("invalid-bot-key")
    end

    assert_response :unauthorized
  end

  private
    def bot_headers(key = @bot.bot_key)
      { "Authorization" => "Bearer #{key}" }
    end
end
