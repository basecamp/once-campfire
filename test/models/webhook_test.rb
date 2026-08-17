require "test_helper"

class WebhookTest < ActiveSupport::TestCase
  test "deliver action" do
    message = messages(:fourth)
    message_path = Rails.application.routes.url_helpers.room_at_message_path(message.room, message)
    bot_messages_path = Rails.application.routes.url_helpers.room_bot_messages_path(message.room, users(:bender).bot_key)
    request = WebMock.stub_request(:post, webhooks(:bender).url).with do |request|
      JSON.parse(request.body) == {
        "type" => "action",
        "id" => "event-123",
        "room" => { "id" => message.room.id, "name" => message.room.name, "path" => bot_messages_path },
        "user" => { "id" => users(:kevin).id, "name" => users(:kevin).name },
        "message" => { "id" => message.id, "path" => message_path },
        "action" => { "value" => "deploy:a1b2c3", "selected" => true }
      }
    end.to_return(status: 200)

    webhooks(:bender).deliver_action(message, users(:kevin), "deploy:a1b2c3", true, event_id: "event-123")

    assert_requested request
  end

  test "action delivery raises on an error response" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 503)

    assert_raises Webhook::DeliveryError do
      webhooks(:bender).deliver_action(messages(:fourth), users(:kevin), "deploy", false, event_id: "event-123")
    end
  end

  test "action delivery wraps network errors for retry" do
    Webhook.any_instance.stubs(:post).raises(Errno::ECONNREFUSED)

    assert_raises Webhook::DeliveryError do
      webhooks(:bender).deliver_action(messages(:fourth), users(:kevin), "deploy", false, event_id: "event-123")
    end
  end

  test "payload" do
    message = messages(:first)
    message_path = Rails.application.routes.url_helpers.room_at_message_path(message.room, message)
    bot_messages_path = Rails.application.routes.url_helpers.room_bot_messages_path(message.room, users(:bender).bot_key)

    WebMock.stub_request(:post, webhooks(:bender).url).
      with(body: hash_including(
        type: "message",
        user: { id: message.creator.id, name: message.creator.name },
        room: { id: message.room.id, name: message.room.name, path: bot_messages_path },
        message: { id: message.id, body: { html: "First post!", plain: "First post!" }, path: message_path },
      ))

    response = webhooks(:bender).deliver(messages(:first))
    assert_equal 200, response.code.to_i
  end

  test "delivery" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200, body: "", headers: {})
    response = webhooks(:bender).deliver(messages(:first))
    assert_equal 200, response.code.to_i
  end

  test "delivery with OK text reply" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200, body: "Hello back!", headers: { "Content-Type" => "text/plain" })
    response = webhooks(:bender).deliver(messages(:first))

    reply_message = Message.last
    assert_equal "Hello back!", reply_message.body.to_plain_text
  end

  test "delivery with OK attachment reply" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200, body: file_fixture("moon.jpg"), headers: { "Content-Type" => "image/jpeg" })
    response = webhooks(:bender).deliver(messages(:first))

    reply_message = Message.last
    assert reply_message.attachment.present?
  end

  test "delivery with error reply" do
    assert_no_difference -> { Message.count } do
      WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 500, body: "Internal Error!", headers: {})
      response = webhooks(:bender).deliver(messages(:first))
    end
  end

  test "delivery that times out" do
    Webhook.any_instance.stubs(:post).raises(Net::OpenTimeout)
    response = webhooks(:bender).deliver(messages(:first))

    reply_message = Message.last
    assert_equal "Failed to respond within 7 seconds", reply_message.body.to_plain_text
  end
end
