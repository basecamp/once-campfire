require "test_helper"

class MessageTest < ActiveSupport::TestCase
  include ActionCable::TestHelper, ActiveJob::TestHelper

  test "creating a message journals recipient push deliveries" do
    message = create_new_message_in rooms(:designers)
    message.message_effects.where(effect: "presence_reconcile").where.not(lease_token: nil).each do |effect|
      effect.perform! effect.lease_token
    end

    assert message.message_effects.where(effect: "push_delivery").exists?
    assert message.message_effects.where(effect: "push_delivery", completed_at: nil).exists?
  end

  test "all emoji" do
    assert Message.new(body: "😄🤘").plain_text_body.all_emoji?
    assert_not Message.new(body: "Haha! 😄🤘").plain_text_body.all_emoji?
    assert_not Message.new(body: "🔥\nmultiple lines\n💯").plain_text_body.all_emoji?
    assert_not Message.new(body: "🔥 💯").plain_text_body.all_emoji?
  end

  test "mentionees" do
    message = Message.new room: rooms(:pets), body: "<div>Hey #{mention_attachment_for(:david)}</div>", creator: users(:jason), client_message_id: "earth"
    assert_equal [ users(:david) ], message.mentionees

    message_with_duplicate_mentions = Message.new room: rooms(:pets), body: "<div>Hey #{mention_attachment_for(:david)} #{mention_attachment_for(:david)}</div>", creator: users(:jason), client_message_id: "earth"
    assert_equal [ users(:david) ], message.mentionees

    message_mentioning_a_non_member = Message.new room: rooms(:pets), body: "<div>Hey #{mention_attachment_for(:kevin)}</div>", creator: users(:jason), client_message_id: "earth"
    assert_equal [], message_mentioning_a_non_member.mentionees
  end

  test "client message id validation counts bytes" do
    boundary_id = "\u00E9" * (ContentLimits::CLIENT_MESSAGE_ID_BYTES / 2)
    message = rooms(:pets).messages.build(
      creator: users(:jason), body: "Boundary ID", client_message_id: boundary_id
    )
    assert_predicate message, :valid?

    message.client_message_id = "#{boundary_id}a"
    assert_not message.valid?
    assert_includes message.errors[:client_message_id],
      "is too long (maximum is #{ContentLimits::CLIENT_MESSAGE_ID_BYTES} bytes)"
  end

  test "database client message IDs are unique across creators within a room" do
    room = rooms(:designers)
    client_message_id = "room-wide-client-id"
    room.messages.create!(creator: users(:jason), body: "First creator", client_message_id:)

    assert_raises ActiveRecord::RecordNotUnique do
      room.messages.create!(creator: users(:david), body: "Second creator", client_message_id:)
    end
  end

  test "DOM identity includes the room while routes retain the database ID" do
    message = messages(:first)

    assert_equal [ message.room_id, message.client_message_id ], message.to_key
    assert_equal message.id.to_s, message.to_param
    assert_equal "message_#{message.room_id}_#{message.client_message_id}", ActionView::RecordIdentifier.dom_id(message)
  end

  private
    def create_new_message_in(room)
      room.messages.create!(creator: users(:jason), body: "Hello", client_message_id: "123")
    end
end
