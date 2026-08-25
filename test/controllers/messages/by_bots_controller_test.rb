require "test_helper"

class Messages::ByBotsControllerTest < ActionDispatch::IntegrationTest
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

  test "create video returns unprocessable content when transcoding fails" do
    movie = mock("movie")
    movie.stubs(:transcode).raises(RuntimeError, "ffmpeg exploded")
    FFMPEG::Movie.stubs(:new).returns(movie)

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room, users(:bender).bot_key), params: {
        attachment: fixture_file_upload("alpha-centuri.mov", "video/quicktime")
      }
    end

    assert_response :unprocessable_content
  ensure
    FFMPEG::Movie.unstub(:new)
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

  test "create without a body or attachment" do
    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room, users(:bender).bot_key)
      assert_response :unprocessable_content

      post room_bot_messages_url(@room, users(:bender).bot_key), params: +"   "
      assert_response :unprocessable_content
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

  test "index returns the room's messages in the order they were sent" do
    get room_bot_messages_url(@room, users(:bender).bot_key)
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal @room.messages.ordered.map(&:id), json.map { it["id"] }
  end

  test "index includes message details" do
    post room_bot_messages_url(@room, users(:bender).bot_key), params: +"Hello from Bender!"

    get room_bot_messages_url(@room, users(:bender).bot_key)
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

    get room_bot_messages_url(@room, users(:bender).bot_key)
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal Message::PAGE_SIZE, json.size
    assert_equal "41", response.headers["X-Total-Count"]
    assert_not_includes json.map { it["id"] }, messages(:fourth).id

    get response.headers["Link"][/<(.*)>/, 1]
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal [ messages(:fourth).id ], json.map { it["id"] }
    assert_nil response.headers["Link"]
  end

  test "index pages newer messages with after" do
    get room_bot_messages_url(@room, users(:bender).bot_key, after: messages(:tenth).id)
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal %i[ eleventh twelfth thirteenth ].map { messages(it).id }, json.map { it["id"] }
    assert_nil response.headers["Link"]
  end

  test "index in a room with no messages" do
    get room_bot_messages_url(rooms(:bender_and_kevin), users(:bender).bot_key)
    assert_response :success

    assert_equal [], JSON.parse(response.body)
    assert_equal "0", response.headers["X-Total-Count"]
    assert_nil response.headers["Link"]
  end

  test "index requires a valid bot key" do
    get room_bot_messages_url(@room, "invalid-bot-key")
    assert_response :redirect
  end

  test "index is not found for a room the bot is not a member of" do
    get room_bot_messages_url(rooms(:designers), users(:bender).bot_key)
    assert_response :not_found
  end

  test "create is not found for a room the bot is not a member of" do
    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(rooms(:designers), users(:bender).bot_key), params: +"Hello!"
    end
    assert_response :not_found
  end

  test "regular messages index remains denied for bots" do
    get room_messages_url(@room, bot_key: users(:bender).bot_key)
    assert_response :forbidden
  end

  test "update" do
    message = post_bot_message "Deploying..."

    assert_no_difference -> { Message.count } do
      patch room_bot_message_url(@room, users(:bender).bot_key, message), params: +"Deployed."
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

    patch room_bot_message_url(@room, users(:bender).bot_key, message), params: +"Deployed 🚀!"

    assert_response :ok
    assert_equal "Deployed 🚀!", message.reload.plain_text_body
    assert_equal "Deployed 🚀!", JSON.parse(response.body)["body"]["plain_text"]
  end

  test "update can't touch a message the bot did not create" do
    message = messages(:fourth)
    original = message.plain_text_body

    patch room_bot_message_url(@room, users(:bender).bot_key, message), params: +"Hijacked!"

    assert_response :forbidden
    assert_equal original, message.reload.plain_text_body
  end

  test "update is not found for a room the bot is not a member of" do
    message = messages(:first)
    original = message.plain_text_body

    patch room_bot_message_url(rooms(:designers), users(:bender).bot_key, message), params: +"Hijacked!"

    assert_response :not_found
    assert_equal original, message.reload.plain_text_body
  end

  test "update can't be abused to edit messages as any user" do
    message = messages(:fourth)
    bot_key = "#{users(:jz).id}-"
    original = message.plain_text_body

    patch room_bot_message_url(@room, bot_key, message), params: +"Hijacked!"

    assert_response :redirect
    assert_equal original, message.reload.plain_text_body
  end

  test "destroy" do
    message = post_bot_message "Deploying..."

    assert_difference -> { Message.count }, -1 do
      delete room_bot_message_url(@room, users(:bender).bot_key, message)
    end

    assert_response :no_content
  end

  test "destroy can't touch a message the bot did not create" do
    message = messages(:fourth)

    assert_no_difference -> { Message.count } do
      delete room_bot_message_url(@room, users(:bender).bot_key, message)
    end

    assert_response :forbidden
  end

  private
    def post_bot_message(body)
      post room_bot_messages_url(@room, users(:bender).bot_key), params: +body
      Message.last
    end
end
