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

  test "denied index" do
    get room_messages_url(@room, bot_key: users(:bender).bot_key, format: :json)
    assert_response :forbidden
  end
end
