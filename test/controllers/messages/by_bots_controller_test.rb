require "test_helper"

class Messages::ByBotsControlleTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
  end

  test "create" do
    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room), params: +"Hello Bot World!", headers: bot_headers
      assert_equal "Hello Bot World!", Message.last.plain_text_body
    end
  end

  test "create with UTF-8 content" do
    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room), params: +"Hello 👋!", headers: bot_headers
      assert_equal "Hello 👋!", Message.last.plain_text_body
    end
  end

  test "create rejects a blank message" do
    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room), params: +"", headers: bot_headers
    end

    assert_response :unprocessable_entity
  end

  test "create rejects an oversized body without reading past the limit" do
    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room),
        params: +("x" * (ContentLimits::MESSAGE_BODY_BYTES + 1)), headers: bot_headers
    end

    assert_response :content_too_large
  end

  test "create file" do
    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room),
        params: { attachment: fixture_file_upload("moon.jpg", "image/jpeg") }, headers: bot_headers
      assert Message.last.attachment.present?
    end
  end

  test "create does not trigger a webhook to the sending bot if it mentions itself" do
    body = "<div>Hey #{mention_attachment_for(:bender)}</div>"

    assert_no_enqueued_jobs only: Bot::WebhookJob do
      perform_enqueued_jobs only: MessageEffectJob do
        post room_bot_messages_url(@room), params: body, headers: bot_headers
      end
    end
  end

  test "create does not trigger a webhook to the sending bot in a direct room" do
    assert_no_enqueued_jobs only: Bot::WebhookJob do
      perform_enqueued_jobs only: MessageEffectJob do
        post room_bot_messages_url(rooms(:bender_and_kevin)),
          params: +"Talking to myself again!", headers: bot_headers
      end
    end
  end

  test "create can't be abused to post messages as any user" do
    user = users(:kevin)
    bot_key = "#{user.id}-"

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(rooms(:bender_and_kevin)),
        params: "Hello 👋!", headers: { "Authorization" => "Bearer #{bot_key}" }
    end

    assert_response :unauthorized
  end

  test "denied index" do
    get room_messages_url(@room, format: :json), headers: bot_headers
    assert_response :forbidden
  end

  test "bot credentials are absent from the request target" do
    bot_key = users(:bender).bot_key

    assert_not_includes URI(room_bot_messages_url(@room)).request_uri, bot_key
    post room_bot_messages_url(@room), params: +"Header only", headers: bot_headers

    assert_response :created
  end

  private
    def bot_headers
      { "Authorization" => "Bearer #{users(:bender).bot_key}" }
    end
end
