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

  test "index rejects an ordinary browser session before looking up the room" do
    sign_in :jz

    get room_bot_messages_url(rooms(:designers))

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

  test "create without a body or attachment" do
    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room), headers: bot_headers
      assert_response :unprocessable_content

      post room_bot_messages_url(@room), params: +"   ", headers: bot_headers
      assert_response :unprocessable_content
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

  test "regular messages index remains denied for bots" do
    get room_messages_url(@room, format: :json), headers: bot_headers
    assert_response :forbidden
  end

  test "bot credentials are absent from the request target" do
    bot_key = users(:bender).bot_key

    assert_not_includes URI(room_bot_messages_url(@room)).request_uri, bot_key
    post room_bot_messages_url(@room), params: +"Header only", headers: bot_headers

    assert_response :created
  end

  test "index returns the room's messages in the order they were sent" do
    get room_bot_messages_url(@room), headers: bot_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal @room.messages.ordered.map(&:id), json.map { it["id"] }
  end

  test "index includes message details" do
    post room_bot_messages_url(@room), params: +"Hello from Bender!", headers: bot_headers

    get room_bot_messages_url(@room), headers: bot_headers
    assert_response :success

    message = Message.last
    json_message = JSON.parse(response.body).last
    assert_equal message.id, json_message["id"]
    assert_equal "Hello from Bender!", json_message["body"]["plain_text"]
    assert_includes json_message["body"]["html"], "Hello from Bender!"
    assert_equal message.created_at.utc.iso8601(3), json_message["created_at"]
    assert_equal users(:bender).id, json_message["creator"]["id"]
    assert_equal "Bender Bot", json_message["creator"]["name"]
    assert_equal "bot", json_message["creator"]["role"]
    assert_equal @room.id, json_message["room"]["id"]
    assert_equal room_message_url(@room, message), json_message["url"]
  end

  test "index pages through older messages with the Link header" do
    (Message::PAGE_SIZE - @room.messages.count + 1).times do |i|
      @room.messages.create!(body: "Filler #{i}", creator: users(:jason), client_message_id: "filler-#{i}")
    end

    get room_bot_messages_url(@room), headers: bot_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal Message::PAGE_SIZE, json.size
    assert_equal "41", response.headers["X-Total-Count"]
    assert_not_includes json.map { it["id"] }, messages(:fourth).id

    get response.headers["Link"][/<(.*)>/, 1], headers: bot_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal [ messages(:fourth).id ], json.map { it["id"] }
    assert_nil response.headers["Link"]
  end

  test "index pages newer messages with after" do
    get room_bot_messages_url(@room, after: messages(:tenth).id), headers: bot_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal %i[ eleventh twelfth thirteenth ].map { messages(it).id }, json.map { it["id"] }
    assert_nil response.headers["Link"]
  end

  test "index in a room with no messages" do
    get room_bot_messages_url(rooms(:bender_and_kevin)), headers: bot_headers
    assert_response :success

    assert_equal [], JSON.parse(response.body)
    assert_equal "0", response.headers["X-Total-Count"]
    assert_nil response.headers["Link"]
  end

  test "index requires a valid bot key" do
    get room_bot_messages_url(@room), headers: bot_headers("invalid-bot-key")
    assert_response :redirect
  end

  test "index is not found for a room the bot is not a member of" do
    get room_bot_messages_url(rooms(:designers)), headers: bot_headers
    assert_response :not_found
  end

  test "create is not found for a room the bot is not a member of" do
    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(rooms(:designers)), params: +"Hello!", headers: bot_headers
    end
    assert_response :not_found
  end

  test "update" do
    message = post_bot_message "Deploying..."

    assert_no_difference -> { Message.count } do
      patch room_bot_message_url(@room, message), params: +"Deployed.", headers: bot_headers
    end

    assert_response :ok
    assert_equal "Deployed.", message.reload.plain_text_body

    json = JSON.parse(response.body)
    assert_equal message.id, json["id"]
    assert_equal "Deployed.", json["body"]["plain_text"]
    assert_equal users(:bender).id, json["creator"]["id"]
    assert_equal room_message_url(@room, message), json["url"]
  end

  test "update with UTF-8 content" do
    message = post_bot_message "Deploying..."

    patch room_bot_message_url(@room, message), params: +"Deployed 🚀!", headers: bot_headers

    assert_response :ok
    assert_equal "Deployed 🚀!", message.reload.plain_text_body
    assert_equal "Deployed 🚀!", JSON.parse(response.body)["body"]["plain_text"]
  end

  test "update can't touch a message the bot did not create" do
    message = messages(:fourth)
    original = message.plain_text_body

    patch room_bot_message_url(@room, message), params: +"Hijacked!", headers: bot_headers

    assert_response :forbidden
    assert_equal original, message.reload.plain_text_body
  end

  test "update is not found for a room the bot is not a member of" do
    message = messages(:first)
    original = message.plain_text_body

    patch room_bot_message_url(rooms(:designers), message), params: +"Hijacked!", headers: bot_headers

    assert_response :not_found
    assert_equal original, message.reload.plain_text_body
  end

  test "update can't be abused to edit messages as any user" do
    message = messages(:fourth)
    bot_key = "#{users(:jz).id}-"
    original = message.plain_text_body

    patch room_bot_message_url(@room, message), params: +"Hijacked!", headers: bot_headers(bot_key)

    assert_response :unauthorized
    assert_equal original, message.reload.plain_text_body
  end

  test "destroy" do
    message = post_bot_message "Deploying..."

    assert_difference -> { Message.count }, -1 do
      delete room_bot_message_url(@room, message), headers: bot_headers
    end

    assert_response :no_content
  end

  test "destroy can't touch a message the bot did not create" do
    message = messages(:fourth)

    assert_no_difference -> { Message.count } do
      delete room_bot_message_url(@room, message), headers: bot_headers
    end

    assert_response :forbidden
  end

  private
    def post_bot_message(body)
      post room_bot_messages_url(@room), params: +body, headers: bot_headers
      Message.last
    end

    def bot_headers(key = users(:bender).bot_key)
      { "Authorization" => "Bearer #{key}" }
    end

    def mention_attachment_for_user(user)
      content = ApplicationController.render partial: "users/mention", locals: { user: }
      escaped_content = content.gsub('"', "&quot;")
      "<action-text-attachment sgid=\"#{user.attachable_sgid}\" " \
        "content-type=\"application/vnd.campfire.mention\" " \
        "content=\"#{escaped_content}\"></action-text-attachment>"
    end
end
