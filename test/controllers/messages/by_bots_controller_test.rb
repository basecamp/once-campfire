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

  test "create with actions" do
    post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
      body: "Deploy to production?",
      selection_mode: "single",
      actions: [
        { label: "Deploy", value: "deploy:a1b2c3", style: "primary" },
        { label: "Cancel", value: "cancel:a1b2c3", style: "danger" }
      ]
    }

    assert_response :created
    assert_equal "Deploy to production?", Message.last.plain_text_body
    assert_equal "deploy:a1b2c3", Message.last.bot_actions.first["value"]
    assert_equal "single", Message.last.bot_action_selection_mode
    assert_equal Message.last.id, response.parsed_body["id"]
    assert_equal "single", response.parsed_body["selection_mode"]
    assert_equal "deploy:a1b2c3", response.parsed_body.dig("actions", 0, "value")
  end

  test "create with an icon and custom color" do
    post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
      body: "Camera alert",
      actions: [
        { label: "Open camera", value: "camera:open", icon: "camera", icon_position: "right", background_color: "#7c3aed", text_color: "#fef08a" }
      ]
    }

    assert_response :created
    assert_equal "camera", Message.last.bot_actions.first["icon"]
    assert_equal "right", Message.last.bot_actions.first["icon_position"]
    assert_equal "#7c3aed", Message.last.bot_actions.first["background_color"]
    assert_equal "#fef08a", Message.last.bot_actions.first["text_color"]
  end

  test "create with an emoji" do
    post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
      body: "Fire alert",
      actions: [ { label: "Investigate", value: "investigate", emoji: "👨‍🚒", icon_position: "right" } ]
    }

    assert_response :created
    assert_equal "👨‍🚒", Message.last.bot_actions.first["emoji"]
  end

  test "create with an icon only action" do
    post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
      body: "Quick actions",
      actions: [ { label: "Open camera", value: "camera:open", icon: "camera", icon_only: true } ]
    }

    assert_response :created
    assert_equal true, Message.last.bot_actions.first["icon_only"]
  end

  test "create with a disabled action" do
    post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
      body: "Voting closed",
      actions: [ { label: "Pizza", value: "food:pizza", emoji: "🍕", disabled: true } ]
    }

    assert_response :created
    assert_equal true, Message.last.bot_actions.first["disabled"]
  end

  test "create with a link action" do
    post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
      body: "Alert firing",
      actions: [ { label: "Open runbook", url: "https://example.com/runbooks/api" } ]
    }

    assert_response :created
    assert_equal "https://example.com/runbooks/api", Message.last.bot_actions.first["url"]
  end

  test "create with a custom app action" do
    post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
      body: "Open the related app",
      actions: [ { label: "Open dashboard", url: "example-app://open/dashboard" } ]
    }

    assert_response :created
    assert_equal "example-app://open/dashboard", Message.last.bot_actions.first["url"]
  end

  test "rejects an unsafe link action" do
    [ "javascript:alert(1)", "data:text/html,bad", "file:///etc/passwd", "/relative/path" ].each do |url|
      assert_no_difference -> { Message.count } do
        assert_raises ActiveRecord::RecordInvalid do
          post room_bot_messages_url(@room, users(:bender).bot_key), as: :json,
            params: { body: "Alert", actions: [ { label: "Run", url: url } ] }
        end
      end
    end
  end

  test "update can replace and remove actions" do
    message = post_bot_message "Deploying..."

    patch room_bot_message_url(@room, users(:bender).bot_key, message), as: :json,
      params: { body: "Choose", selection_mode: "multiple", actions: [ { label: "Cancel", value: "cancel" } ] }

    assert_response :ok
    assert_equal [ "cancel" ], message.reload.bot_actions.pluck("value")
    assert_equal "multiple", message.bot_action_selection_mode

    patch room_bot_message_url(@room, users(:bender).bot_key, message), as: :json,
      params: { body: "Done", actions: [] }

    assert_response :ok
    assert_empty message.reload.bot_actions
  end

  test "rejects invalid actions" do
    assert_no_difference -> { Message.count } do
      assert_raises ActiveRecord::RecordInvalid do
        post room_bot_messages_url(@room, users(:bender).bot_key), as: :json,
          params: { body: "Pick", actions: 13.times.map { |index| { label: "Option", value: index.to_s } } }
      end
    end
  end

  test "accepts a zero to ten rating" do
    post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
      body: "Rate from 0 to 10",
      selection_mode: "single",
      actions: 11.times.map { |rating| { label: "Rate #{rating}", value: "rating:#{rating}" } }
    }

    assert_response :created
    assert_equal 11, Message.last.bot_actions.size
  end

  test "rejects invalid action appearance" do
    [
      { icon: "../../../secret" },
      { icon: "camera", icon_position: "middle" },
      { icon: "camera", emoji: "📷" },
      { emoji: "not an emoji" },
      { emoji: "🔥📷" },
      { icon_position: "right" },
      { icon_only: true },
      { icon: "camera", icon_only: "yes" },
      { disabled: "yes" },
      { background_color: "red; display: none" },
      { background_color: 123 },
      { text_color: "#ffffff" },
      { background_color: "#000000", text_color: 123 },
      { text_color: "white; display: none" }
    ].each do |appearance|
      assert_no_difference -> { Message.count } do
        assert_raises ActiveRecord::RecordInvalid do
          post room_bot_messages_url(@room, users(:bender).bot_key), as: :json,
            params: { body: "Alert", actions: [ { label: "Open", value: "open", **appearance } ] }
        end
      end
    end
  end

  test "rejects duplicate action values" do
    assert_no_difference -> { Message.count } do
      assert_raises ActiveRecord::RecordInvalid do
        post room_bot_messages_url(@room, users(:bender).bot_key), as: :json, params: {
          body: "Pick",
          actions: [
            { label: "First", value: "same" },
            { label: "Second", value: "same" }
          ]
        }
      end
    end
  end

  test "rejects value actions when the bot has no webhook" do
    users(:bender).webhook.destroy!

    assert_no_difference -> { Message.count } do
      assert_raises ActiveRecord::RecordInvalid do
        post room_bot_messages_url(@room, users(:bender).bot_key), as: :json,
          params: { body: "Deploy?", actions: [ { label: "Deploy", value: "deploy" } ] }
      end
    end
  end

  test "allows link actions when the bot has no webhook" do
    users(:bender).webhook.destroy!

    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room, users(:bender).bot_key), as: :json,
        params: { body: "Runbook", actions: [ { label: "Open", url: "https://example.com/runbook" } ] }
    end

    assert_response :created
  end

  test "rejects an invalid action selection mode" do
    assert_no_difference -> { Message.count } do
      assert_raises ActiveRecord::RecordInvalid do
        post room_bot_messages_url(@room, users(:bender).bot_key), as: :json,
          params: { body: "Pick", selection_mode: "everything", actions: [ { label: "One", value: "one" } ] }
      end
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
