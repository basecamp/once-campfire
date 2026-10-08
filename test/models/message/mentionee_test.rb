require "test_helper"

class Message::MentioneeTest < ActiveSupport::TestCase
  test "ordinary messages return an empty user relation without loading their room" do
    message = rooms(:pets).messages.create!(creator: users(:jason), body: "<p>Fish &amp; chips 🌍</p>").reload
    message.body
    assert_not message.association(:room).loaded?
    queries = []
    subscriber = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      mentionees = message.mentionees
      assert_equal User, mentionees.klass
      assert_empty mentionees.to_a
      assert_empty mentionees.ids
      assert_empty mentionees.active_bots.excluding(users(:jason)).to_a
    end

    assert_empty queries
    assert_not message.association(:room).loaded?
    assert_not message.changed?
  end

  test "signed mentions follow a moved message and fresh membership changes" do
    message = rooms(:designers).messages.create!(creator: users(:david), body: "<p>Hey #{mention_attachment_for(:kevin)}</p>")
    assert_equal [ users(:kevin).id ], message.reload.mentionees.ids
    Message.where(id: message.id).update_all(room_id: rooms(:pets).id)
    message = Message.find(message.id)
    assert_empty message.mentionees.ids

    membership = Membership.create!(room: rooms(:pets), user: users(:kevin))
    assert_equal [ users(:kevin).id ], message.mentionees.ids
    membership.delete
    assert_empty message.mentionees.ids
    assert_equal rooms(:pets).id, message.room_id
    assert_not message.changed?
  end
end
