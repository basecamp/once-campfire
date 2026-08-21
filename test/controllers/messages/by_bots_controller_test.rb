require "test_helper"

class Messages::ByBotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
  end

  test "create" do
    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room), params: +"Hello Bot World!", headers: bot_headers
      assert_equal "Hello Bot World!", Message.last.plain_text_body
      assert_equal Message::ORIGIN_BOT_API, Message.last.origin
    end

    assert_response :created
    assert_equal room_at_message_url(@room, Message.last), response.headers["Location"]
  end

  test "create rejects an ordinary browser session" do
    sign_in :jz

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room), params: +"Browser-originated bot message"
    end

    assert_response :forbidden
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

  test "an old bot key cannot commit an upload after key reset" do
    bot = users(:bender)
    actor = users(:david)
    old_key = bot.bot_key
    original_stage = StagedUpload.method(:stage)
    StagedUpload.define_singleton_method(:stage) do |*arguments, **options|
      original_stage.call(*arguments, **options).tap do
        User.find(bot.id).reset_bot_key!(actor:)
      end
    end

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room),
        params: { attachment: fixture_file_upload("moon.jpg", "image/jpeg") },
        headers: { "Authorization" => "Bearer #{old_key}" }
    end

    assert_response :forbidden
    assert_not_equal old_key, bot.reload.bot_key
  ensure
    StagedUpload.define_singleton_method(:stage, original_stage) if original_stage
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

  test "a bot API message cannot invoke a different mentioned bot" do
    recipient = User.create_bot!({
      name: "Second Bot", webhook_url: "https://example.com/second-bot"
    }, actor: users(:david))
    Membership.create!(room: @room, user: recipient)
    body = "<div>Hey #{mention_attachment_for_user(recipient)}</div>"

    post room_bot_messages_url(@room), params: body, headers: bot_headers

    assert_response :created
    message = Message.last
    assert_not message.message_effects.exists?(effect: "webhook_fanout")
    assert_not message.message_effects.exists?(effect: "bot_webhook", recipient_id: recipient.id)
  end

  test "two bots in a direct room cannot recurse through their webhooks" do
    recipient = User.create_bot!({
      name: "Second Bot", webhook_url: "https://example.com/second-bot"
    }, actor: users(:david))
    room = Rooms::Direct.find_or_create_for(
      [ users(:bender), recipient ], actor: users(:bender)
    )
    request = WebMock.stub_request(:post, recipient.webhook.url).to_raise("must not deliver")

    perform_enqueued_jobs only: MessageEffectJob do
      post room_bot_messages_url(room), params: +"Automated direct message", headers: bot_headers
    end

    assert_response :created
    message = Message.last
    assert_equal users(:bender), message.creator
    assert_not message.message_effects.exists?(effect: %w[ webhook_fanout bot_webhook ])
    assert_not_requested request
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

    def mention_attachment_for_user(user)
      content = ApplicationController.render partial: "users/mention", locals: { user: }
      escaped_content = content.gsub('"', "&quot;")
      "<action-text-attachment sgid=\"#{user.attachable_sgid}\" " \
        "content-type=\"application/vnd.campfire.mention\" " \
        "content=\"#{escaped_content}\"></action-text-attachment>"
    end
end
