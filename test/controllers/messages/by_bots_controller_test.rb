require "test_helper"

class Messages::ByBotsControlleTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
  end

  test "create" do
    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room, users(:bender).bot_key), params: +"Hello Bot World!"
      assert_equal "Hello Bot World!", Message.last.plain_text_body
    end
  end

  test "create with UTF-8 content" do
    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room, users(:bender).bot_key), params: +"Hello 👋!"
      assert_equal "Hello 👋!", Message.last.plain_text_body
    end
  end

  test "create file" do
    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room, users(:bender).bot_key), params: { attachment: fixture_file_upload("moon.jpg", "image/jpeg") }
      assert Message.last.attachment.present?
    end
  end

  test "create does not trigger a webhook to the sending bot if it mentions itself" do
    body = "<div>Hey #{mention_attachment_for(:bender)}</div>"

    assert_no_enqueued_jobs only: Bot::WebhookJob do
      post room_bot_messages_url(@room, users(:bender).bot_key), params: body
    end
  end

  test "create does not trigger a webhook to the sending bot in a direct room" do
    assert_no_enqueued_jobs only: Bot::WebhookJob do
      post room_bot_messages_url(rooms(:bender_and_kevin), users(:bender).bot_key), params: +"Talking to myself again!"
    end
  end

  test "create can't be abused to post messages as any user" do
    user = users(:kevin)
    bot_key = "#{user.id}-"

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(rooms(:bender_and_kevin), bot_key), params: "Hello 👋!"
    end

    assert_response :redirect
  end

  test "index returns messages as JSON" do
    get room_bot_messages_index_url(@room, users(:bender).bot_key)
    assert_response :success

    json = JSON.parse(response.body)
    assert json["room"]["id"].present?
    assert json["room"]["name"].present?
    assert json["messages"].is_a?(Array)
    assert json["pagination"].present?
  end

  test "index includes message details" do
    # Create a message in the room first
    post room_bot_messages_url(@room, users(:bender).bot_key), params: +"Test message for index"

    get room_bot_messages_index_url(@room, users(:bender).bot_key)
    assert_response :success

    json = JSON.parse(response.body)
    message = json["messages"].find { |m| m["body"]["plain"] == "Test message for index" }
    assert message.present?, "Expected to find the test message"
    assert message["id"].present?
    assert message["created_at"].present?
    assert message["creator"]["id"].present?
    assert message["creator"]["name"].present?
  end

  test "index supports pagination with before parameter" do
    get room_bot_messages_index_url(@room, users(:bender).bot_key, before: Message.last.id)
    assert_response :success
  end

  test "index supports pagination with after parameter" do
    get room_bot_messages_index_url(@room, users(:bender).bot_key, after: Message.first.id)
    assert_response :success
  end

  test "index requires valid bot key" do
    get room_bot_messages_index_url(@room, "invalid-bot-key")
    assert_response :redirect  # Redirects to login
  end

  test "index returns not_found for room bot is not a member of" do
    # bender bot is NOT a member of the designers room
    room_without_bot = rooms(:designers)
    get room_bot_messages_index_url(room_without_bot, users(:bender).bot_key)
    assert_response :not_found
  end

  test "index works for room bot IS a member of" do
    # bender bot IS a member of watercooler
    room_with_bot = rooms(:watercooler)
    get room_bot_messages_index_url(room_with_bot, users(:bender).bot_key)
    assert_response :success
  end

  test "create returns not_found for room bot is not a member of" do
    # bender bot is NOT a member of the designers room - verify create matches index behavior
    room_without_bot = rooms(:designers)
    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(room_without_bot, users(:bender).bot_key), params: +"Hello!"
    end
    assert_response :not_found
  end

  test "regular messages index still denied for bots" do
    # The standard messages endpoint (not the bot-specific one) should still be forbidden
    get room_messages_url(@room, bot_key: users(:bender).bot_key)
    assert_response :forbidden
  end
end
