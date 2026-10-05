require "test_helper"
require "active_record/testing/query_assertions"

class MessageTest < ActiveSupport::TestCase
  include ActionCable::TestHelper, ActiveJob::TestHelper, ActiveRecord::Assertions::QueryAssertions

  test "creating a message enqueues to push later" do
    assert_enqueued_jobs 1, only: [ Room::PushMessageJob ] do
      create_new_message_in rooms(:designers)
    end
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

  test "presentation associations load together" do
    messages(:first).attachment.attach io: StringIO.new("hello"), filename: "hello.txt", content_type: "text/plain"
    presented = Message.where(id: [ messages(:first).id, messages(:thirteenth).id ]).with_presentation.to_a

    assert_no_queries do
      presented.each do |message|
        message.room.name
        message.creator.avatar.attached?
        message.body.body.to_html
        message.body.embeds.each(&:filename)
        message.attachment.blob&.filename
        message.boosts.each { |boost| boost.booster.avatar.attached? }
      end
    end
  end

  test "presentation pages preload only the rendered messages" do
    page = rooms(:watercooler).messages.with_presentation.last_page
    assert_kind_of Array, page
    assert page.all? { |message| !message.association(:rich_text_body).loaded? }

    rendered = page.first(2)
    page.preload_associations(rendered)

    assert_no_queries { rendered.each { |message| message.body.to_plain_text } }
    assert page.drop(2).all? { |message| !message.association(:rich_text_body).loaded? }
  end

  test "pagination retains the original ordering even when timestamps tie" do
    room = rooms(:watercooler)
    room.messages.update_all(created_at: Time.current)
    expected = room.messages.ordered.last(Message::Pagination::PAGE_SIZE).map(&:id)

    assert_equal expected, room.messages.last_page.map(&:id)
    assert_equal room.messages.ordered.first(Message::Pagination::PAGE_SIZE).map(&:id), room.messages.first_page.map(&:id)
  end

  private
    def create_new_message_in(room)
      room.messages.create!(creator: users(:jason), body: "Hello", client_message_id: "123")
    end
end
