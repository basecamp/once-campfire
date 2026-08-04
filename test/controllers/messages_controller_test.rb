require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"

    sign_in :david
    @room = rooms(:watercooler)
    @messages = @room.messages.ordered.to_a
  end

  test "index returns the last page by default" do
    get room_messages_url(@room)

    assert_response :success
    ensure_messages_present @messages.last
  end

  test "index returns a page before the specified message" do
    get room_messages_url(@room, before: @messages.third)

    assert_response :success
    ensure_messages_present @messages.first, @messages.second
    ensure_messages_not_present @messages.third, @messages.fourth, @messages.fifth
  end

  test "index returns a page after the specified message" do
    get room_messages_url(@room, after: @messages.third)

    assert_response :success
    ensure_messages_present @messages.fourth, @messages.fifth
    ensure_messages_not_present @messages.first, @messages.second, @messages.third
  end

  test "index returns no_content when there are no messages" do
    @room.messages.destroy_all

    get room_messages_url(@room)

    assert_response :no_content
  end

  test "get renders a single message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    get room_message_url(@room, message)

    assert_response :success
  end

  test "creating a message broadcasts the message to the room" do
    perform_enqueued_jobs only: MessageEffectJob do
      post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one", client_message_id: 999 } }
    end

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "append", target: [ @room, :messages ] do
      assert_select ".message__body", text: /New one/
      assert_copy_link_button room_at_message_url(@room, Message.last, host: "once.campfire.test")
    end
  end

  test "creating a message broadcasts unread room" do
    recipient = users(:jason)
    assert_broadcasts UnreadRoomsChannel.broadcasting_for(recipient), 1 do
      perform_enqueued_jobs only: MessageEffectJob do
        post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one", client_message_id: 999 } }
      end
    end
  end

  test "retrying a committed client message id does not duplicate the message" do
    request_params = { message: { body: "Only once", client_message_id: "stable-retry-id" } }

    assert_difference -> { @room.messages.where(creator: users(:david), client_message_id: "stable-retry-id").count }, +1 do
      post room_messages_url(@room, format: :turbo_stream), params: request_params
      post room_messages_url(@room, format: :turbo_stream), params: request_params
    end

    assert_equal "Only once", @room.messages.find_by!(client_message_id: "stable-retry-id").plain_text_body
  end

  test "a client message ID owned by another creator returns conflict without mutation" do
    existing = @room.messages.where.not(creator: users(:david)).first
    original_body = existing.plain_text_body

    assert_no_difference [ -> { Message.count }, -> { Message::Effect.count } ] do
      post room_messages_url(@room, format: :turbo_stream), params: {
        message: { body: "Must not replace", client_message_id: existing.client_message_id }
      }
    end

    assert_response :conflict
    assert_empty response.body
    assert_equal original_body, existing.reload.plain_text_body
  end

  test "create returns not found in every format after membership revocation" do
    memberships(:david_watercooler).delete

    assert_create_not_found_for_each_format room_messages_url(@room)
  end

  test "create returns not found in every format after room deletion" do
    url = room_messages_url(@room)
    @room.destroy!

    assert_create_not_found_for_each_format url
  end

  test "accepts a client message id at the byte limit" do
    client_message_id = "\u00E9" * (ContentLimits::CLIENT_MESSAGE_ID_BYTES / 2)
    assert_equal ContentLimits::CLIENT_MESSAGE_ID_BYTES, client_message_id.bytesize

    assert_difference -> { @room.messages.count }, +1 do
      post room_messages_url(@room, format: :turbo_stream), params: {
        message: { body: "Boundary ID", client_message_id: }
      }
    end

    assert_response :success
    message = @room.messages.find_by!(creator: users(:david), client_message_id:)
    assert_not_empty message.message_effects
    assert message.message_effects.all? { _1.message_client_id == client_message_id }
  end

  test "rejects an oversized client message id without creating durable records" do
    client_message_id = ("\u00E9" * (ContentLimits::CLIENT_MESSAGE_ID_BYTES / 2)) + "a"
    assert_equal ContentLimits::CLIENT_MESSAGE_ID_BYTES + 1, client_message_id.bytesize

    assert_no_difference [ -> { @room.messages.count }, -> { Message::Effect.count } ] do
      post room_messages_url(@room, format: :turbo_stream), params: {
        message: { body: "Oversized ID", client_message_id: }
      }
    end

    assert_response :content_too_large
  end

  test "rejects a blank client message id without creating durable records" do
    assert_no_difference [ -> { @room.messages.count }, -> { Message::Effect.count } ] do
      post room_messages_url(@room, format: :turbo_stream), params: {
        message: { body: "Blank ID", client_message_id: "" }
      }
    end

    assert_response :unprocessable_entity
  end

  test "rejects a message without text or an attachment" do
    assert_no_difference -> { @room.messages.count } do
      post room_messages_url(@room, format: :turbo_stream), params: {
        message: { body: "", client_message_id: "blank-message" }
      }
    end

    assert_response :unprocessable_entity
  end

  test "rejects an oversized message body" do
    assert_no_difference -> { @room.messages.count } do
      post room_messages_url(@room, format: :turbo_stream), params: {
        message: {
          body: "x" * (ContentLimits::MESSAGE_BODY_BYTES + 1),
          client_message_id: "oversized-message"
        }
      }
    end

    assert_response :content_too_large
  end

  test "update updates a message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    Turbo::StreamsChannel.expects(:broadcast_replace_to).once
    put room_message_url(@room, message), params: { message: { body: "Updated body" } }

    assert_redirected_to room_message_url(@room, message)
    assert_equal "Updated body", message.reload.plain_text_body
  end

  test "update rejects attachment replacement parameters without mutating the message" do
    message = @room.messages.where(creator: users(:david)).first
    original_client_message_id = message.client_message_id

    put room_message_url(@room, message), params: {
      message: {
        body: "Must not commit", client_message_id: "replacement-id",
        attachment: fixture_file_upload("moon.jpg", "image/jpeg")
      }
    }

    assert_response :bad_request
    assert_equal original_client_message_id, message.reload.client_message_id
    assert_not_equal "Must not commit", message.plain_text_body
    assert_not message.attachment.attached?
  end

  test "admin updates a message belonging to another user" do
    message = @room.messages.where(creator: users(:jason)).first

    Turbo::StreamsChannel.expects(:broadcast_replace_to).once
    put room_message_url(@room, message), params: { message: { body: "Updated body" } }

    assert_redirected_to room_message_url(@room, message)
    assert_equal "Updated body", message.reload.plain_text_body
  end

  test "destroy destroys a message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    assert_difference -> { Message.count }, -1 do
      Turbo::StreamsChannel.expects(:broadcast_remove_to).once
      delete room_message_url(@room, message, format: :turbo_stream)
      assert_response :success
    end
  end

  test "admin destroy destroys a message belonging to another user" do
    assert users(:david).administrator?
    message = @room.messages.where(creator: users(:jason)).first

    assert_difference -> { Message.count }, -1 do
      Turbo::StreamsChannel.expects(:broadcast_remove_to).once
      delete room_message_url(@room, message, format: :turbo_stream)
      assert_response :success
    end
  end

  test "ensure non-admin can't update a message belonging to another user" do
    sign_in :jz
    assert_not users(:jz).administrator?

    room = rooms(:designers)
    message = room.messages.where(creator: users(:jason)).first

    put room_message_url(room, message), params: { message: { body: "Updated body" } }
    assert_response :forbidden
  end

  test "ensure non-admin can't destroy a message belonging to another user" do
    sign_in :jz
    assert_not users(:jz).administrator?

    room = rooms(:designers)
    message = room.messages.where(creator: users(:jason)).first

    delete room_message_url(room, message, format: :turbo_stream)
    assert_response :forbidden
  end

  test "mentioning a bot triggers a webhook" do
    request = WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    perform_enqueued_jobs only: MessageEffectJob do
      post room_messages_url(@room, format: :turbo_stream), params: { message: {
        body: "<div>Hey #{mention_attachment_for(:bender)}</div>", client_message_id: 999 } }
    end

    assert_requested request, times: 1
  end

  private
    def assert_create_not_found_for_each_format(url)
      formats = {
        html: "text/html",
        turbo_stream: "text/vnd.turbo-stream.html",
        json: "application/json"
      }

      assert_no_difference -> { Message.count } do
        formats.each do |name, accept|
          post url,
            params: { message: { body: "Must not send", client_message_id: "missing-room-#{name}" } },
            headers: { "Accept" => accept }

          assert_response :not_found
          assert_empty response.body
        end
      end
    end

    def ensure_messages_present(*messages, count: 1)
      messages.each do |message|
        assert_select "#" + dom_id(message), count:
      end
    end

    def ensure_messages_not_present(*messages)
      ensure_messages_present *messages, count: 0
    end

    def assert_copy_link_button(url)
      assert_select ".btn[title='Copy link'][data-copy-to-clipboard-content-value='#{url}']"
    end
end
