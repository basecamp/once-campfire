require "test_helper"

class WebhookTest < ActiveSupport::TestCase
  setup do
    Membership.create_or_find_by!(room: rooms(:designers), user: users(:bender))
    @delivery_id = "123e4567-e89b-42d3-a456-426614174001"
  end

  test "payload" do
    message = messages(:first)
    message_path = Rails.application.routes.url_helpers.room_at_message_path(message.room, message)
    bot_messages_path = Rails.application.routes.url_helpers.room_bot_messages_path(message.room)
    bot_authorization = "Bearer #{users(:bender).bot_key}"

    WebMock.stub_request(:post, webhooks(:bender).url).
      with(body: hash_including(
        user: { id: message.creator.id, name: message.creator.name },
        room: {
          id: message.room.id, name: message.room.name, path: bot_messages_path,
          authorization: bot_authorization
        },
        message: { id: message.id, body: { html: "First post!", plain: "First post!" }, path: message_path },
      ))

    response = webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)
    assert_equal 200, response.code.to_i
  end

  test "delivery" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200, body: "", headers: {})
    response = webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)
    assert_equal 200, response.code.to_i
  end

  test "delivery with OK text reply" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200, body: "Hello back!", headers: { "Content-Type" => "text/plain" })
    response = webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)

    reply_message = Message.last
    assert_equal "Hello back!", reply_message.body.to_plain_text
    assert reply_message.message_effects.exists?(effect: "broadcast_create")
    assert reply_message.message_effects.exists?(effect: "room_receive")
    assert_not reply_message.message_effects.exists?(effect: %w[ webhook_fanout bot_webhook ])
  end

  test "delivery with OK attachment reply" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200, body: file_fixture("moon.jpg"), headers: { "Content-Type" => "image/jpeg" })
    response = webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)

    reply_message = Message.last
    assert reply_message.attachment.present?
    assert reply_message.message_effects.exists?(effect: "broadcast_create")
    assert reply_message.message_effects.exists?(effect: "room_receive")
    assert_not reply_message.message_effects.exists?(effect: %w[ webhook_fanout bot_webhook ])
  end

  test "an explicit bot message still fans out to other webhooks" do
    message = rooms(:designers).messages.create_with_attachment!(
      body: "Bot API message", creator: users(:bender), client_message_id: SecureRandom.hex(8), webhook_reply: true
    )

    assert message.message_effects.exists?(effect: "webhook_fanout")
  end

  test "a rich text webhook reply cannot invoke another bot" do
    recipient = User.create_bot!({
      name: "Second Bot", webhook_url: "https://example.com/second-bot"
    }, actor: users(:david))
    Membership.create!(room: rooms(:designers), user: recipient)
    body = "<div>Automated follow-up #{mention_attachment_for_user(recipient)}</div>"
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(
      status: 200, body:, headers: { "Content-Type" => "text/html" }
    )

    webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)

    reply = Message.find_by!(creator: users(:bender), client_message_id: "webhook-reply-#{@delivery_id}")
    assert_not reply.message_effects.exists?(effect: %w[ webhook_fanout bot_webhook ])
  end

  test "delivery with error reply" do
    assert_no_difference -> { Message.count } do
      WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 500, body: "Internal Error!", headers: {})
      assert_raises(Webhook::DeliveryError) do
        webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)
      end
    end
  end

  test "delivery timeout remains retryable and creates no reply" do
    Webhook.any_instance.stubs(:post).raises(Webhook::RetryableDeliveryError, "timed out")

    assert_no_difference -> { Message.count } do
      assert_raises(Webhook::RetryableDeliveryError) do
        webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)
      end
    end
  end

  test "rejects a declared oversized response before creating a reply" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(
      status: 200, body: "not read",
      headers: { "Content-Type" => "application/octet-stream", "Content-Length" => ContentLimits::WEBHOOK_RESPONSE_BYTES + 1 }
    )

    assert_no_difference -> { Message.count } do
      assert_raises(ContentLimits::Exceeded) do
        webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)
      end
    end
  end

  test "rejects an oversized text reply" do
    body = "x" * (ContentLimits::MESSAGE_BODY_BYTES + 1)
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(
      status: 200, body:, headers: { "Content-Type" => "text/plain" }
    )

    assert_no_difference -> { Message.count } do
      assert_raises(ContentLimits::Exceeded) do
        webhooks(:bender).deliver(messages(:first), delivery_id: @delivery_id)
      end
    end
  end

  test "sends the persisted delivery UUID as the idempotency key" do
    request = WebMock.stub_request(:post, webhooks(:bender).url)
      .with(headers: { Webhook::IDEMPOTENCY_HEADER => @delivery_id }).to_return(status: 204)

    webhooks(:bender).deliver messages(:first), delivery_id: @delivery_id

    assert_requested request, times: 1
  end

  test "rejects non-HTTPS, alternate-port, credentialed, and private literal URLs" do
    urls = [
      "http://example.com/hook",
      "https://example.com:8443/hook",
      "https://user:password@example.com/hook",
      "https://127.0.0.1/hook",
      "https://169.254.169.254/hook"
    ]

    urls.each do |url|
      webhook = Webhook.new(user: users(:bender), url:)
      assert_not webhook.valid?, url
      assert webhook.errors[:url].present?, url
    end
  end

  test "rejects a hostname when any resolved address is private" do
    Resolv.stubs(:getaddresses).with("mixed.example.test")
      .returns([ "93.184.216.34", "127.0.0.1" ])

    assert_raises(Webhook::Endpoint::Denied) do
      Webhook::Endpoint.resolve(
        "https://mixed.example.test/hook",
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      )
    end
  end

  test "rejects oversized response headers" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(
      status: 200, body: "", headers: { "X-Oversized" => "x" * Webhook::MAXIMUM_RESPONSE_HEADER_BYTES }
    )

    assert_raises(Webhook::DeliveryError) do
      webhooks(:bender).deliver messages(:first), delivery_id: @delivery_id
    end
  end

  test "rejects an oversized response header line before parsing" do
    with_raw_tls_response(oversized_raw_response_header) do |server|
      http_client = server.http_client
      Net::HTTP.stubs(:new).with("example.com", 443, nil).returns(http_client)

      error = assert_raises(Webhook::DeliveryError) do
        webhooks(:bender).deliver messages(:first), delivery_id: @delivery_id
      end

      assert_instance_of RestrictedHTTP::ResponseHeaderGuard::Exceeded, error.cause
    end
  end

  test "rejects excessive response header lines before parsing" do
    with_raw_tls_response(excessive_raw_response_headers) do |server|
      http_client = server.http_client
      Net::HTTP.stubs(:new).with("example.com", 443, nil).returns(http_client)

      error = assert_raises(Webhook::DeliveryError) do
        webhooks(:bender).deliver messages(:first), delivery_id: @delivery_id
      end

      assert_instance_of RestrictedHTTP::ResponseHeaderGuard::Exceeded, error.cause
    end
  end

  private
    def mention_attachment_for_user(user)
      content = ApplicationController.render partial: "users/mention", locals: { user: }
      escaped_content = content.gsub('"', "&quot;")
      "<action-text-attachment sgid=\"#{user.attachable_sgid}\" " \
        "content-type=\"application/vnd.campfire.mention\" " \
        "content=\"#{escaped_content}\"></action-text-attachment>"
    end
end
