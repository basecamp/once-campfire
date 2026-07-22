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
    post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one", client_message_id: 999 } }

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "append", target: [ @room, :messages ] do
      assert_select ".message__body", text: /New one/
      assert_copy_link_button room_at_message_url(@room, Message.last, host: "once.campfire.test")
    end
  end

  test "creating a message broadcasts unread room" do
    assert_broadcasts "unread_rooms", 1 do
      post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one", client_message_id: 999 } }
    end
  end

  test "update updates a message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    Turbo::StreamsChannel.expects(:broadcast_replace_to).once
    put room_message_url(@room, message), params: { message: { body: "Updated body" } }

    assert_redirected_to room_message_url(@room, message)
    assert_equal "Updated body", message.reload.plain_text_body
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

  test "legacy message edit path does not render poll editor" do
    message = rooms(:designers).messages.create!(creator: users(:jason), client_message_id: SecureRandom.uuid)
    message.create_poll!(question: "Ready?", options_attributes: [ { body: "Yep", position: 0 }, { body: "Nope", position: 1 } ])

    get edit_room_message_url(message.room, message)

    assert_response :unprocessable_entity
  end

  test "legacy message edit path remains forbidden for poll non-admin non-creator" do
    sign_in :kevin
    message = rooms(:designers).messages.create!(creator: users(:jason), client_message_id: SecureRandom.uuid)
    message.create_poll!(question: "Ready?", options_attributes: [ { body: "Yep", position: 0 }, { body: "Nope", position: 1 } ])

    get edit_room_message_url(message.room, message)

    assert_response :forbidden
  end

  test "mentioning a bot triggers a webhook" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    assert_enqueued_jobs 1, only: Bot::WebhookJob do
      post room_messages_url(@room, format: :turbo_stream), params: { message: {
        body: "<div>Hey #{mention_attachment_for(:bender)}</div>", client_message_id: 999 } }
    end
  end

  private
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
