require "test_helper"

class Message::CreationTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess

  setup do
    @room = rooms(:designers)
    @creator = users(:david)
  end

  test "creation indexes persisted native HTML and mentions before notifying" do
    html = "<p>Fish &amp; chips 🌍 #{mention_attachment_for(:jason)}</p>"
    message = @room.messages.new(creator: @creator, body: html)
    original = message.method(:create_in_index)
    message.define_singleton_method(:create_in_index) do
      raise "rich text not autosaved" unless ActionText::RichText.exists?(record: self)
      original.call
    end

    message.save!

    assert_equal message.body.to_plain_text, indexed_body(message)
    assert_equal message.reload.body.to_plain_text, indexed_body(message)
    assert_includes message.mentionees, users(:jason)
    assert_equal [ message ], @room.messages.search("Fish chips")
    assert_no_match(/<p>|&amp;/, indexed_body(message))
  end

  test "an attachment-only message is attached before its filename is indexed" do
    message = @room.messages.new(creator: @creator, attachment: fixture_file_upload("moon.jpg", "image/jpeg"))
    original = message.method(:create_in_index)
    message.define_singleton_method(:create_in_index) do
      raise "attachment not autosaved" unless ActiveStorage::Attachment.exists?(record: self, name: "attachment")
      original.call
    end

    message.save!

    assert_equal "moon.jpg", indexed_body(message)
    assert_equal [ message ], @room.messages.search("moon")
  end

  test "a failed index insert rolls back the message and its associations without notifications" do
    message = @room.messages.new(creator: @creator, body: "<p>Failed &amp; indexed</p>",
      attachment: fixture_file_upload("moon.jpg", "image/jpeg"))
    message.define_singleton_method(:create_in_index) { raise "index unavailable" }

    assert_rolled_back_creation(message) do
      assert_raises(RuntimeError) { message.save! }
    end
  end

  test "a failed unread update rolls back the already inserted index and associations" do
    message = @room.messages.new(creator: @creator, body: "<p>Unread &amp; rollback</p>",
      attachment: fixture_file_upload("moon.jpg", "image/jpeg"))
    original = @room.method(:unread_memberships)
    @room.define_singleton_method(:unread_memberships) do |created|
      original.call(created)
      raise "unread unavailable"
    end

    assert_rolled_back_creation(message) do
      assert_raises(RuntimeError) { message.save! }
    end
  end

  test "an outer rollback restores the index unread state and counter and queues no jobs" do
    message = @room.messages.new(creator: @creator, body: "<p>Outer &amp; rollback</p>")

    assert_rolled_back_creation(message) do
      Message.transaction(requires_new: true) do
        message.save!
        assert_equal "Outer & rollback", indexed_body(message)
        raise ActiveRecord::Rollback
      end
    end
  end

  test "the existing public receive operation still marks unread and queues a push" do
    message = messages(:first)
    room = message.room
    room.expects(:unread_memberships).with(message)
    assert_enqueued_with(job: Room::PushMessageJob, args: [ room, message ]) { room.receive(message) }
  end

  private
    def indexed_body(message)
      Message.connection.select_value(Message.sanitize_sql([ "SELECT body FROM message_search_index WHERE rowid = ?", message.id ]))
    end

    def assert_rolled_back_creation(message)
      models = [ Message, ActionText::RichText, ActiveStorage::Attachment, ActiveStorage::Blob ]
      counts = models.map(&:count)
      memberships = @room.memberships.order(:id).map(&:attributes)
      room_state = @room.reload.attributes.slice("messages_count", "updated_at")
      indexed = Message.connection.select_value("SELECT COUNT(*) FROM message_search_index")
      clear_enqueued_jobs

      yield

      assert_equal counts, models.map(&:count)
      assert_equal indexed, Message.connection.select_value("SELECT COUNT(*) FROM message_search_index")
      assert_equal memberships, @room.memberships.order(:id).map(&:attributes)
      assert_equal room_state, @room.reload.attributes.slice("messages_count", "updated_at")
      assert_enqueued_jobs 0
    end
end

class MessageCreationCommitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "creation commits its index and unread writes once before enqueuing push" do
    room = rooms(:designers)
    sql = []
    collect = ->(*, payload) { sql << payload[:sql] }
    Room::PushMessageJob.expects(:perform_later).with do |queued_room, message|
      assert_not Message.connection.transaction_open?
      assert_equal room, queued_room
      assert_equal "One native commit", Message.connection.select_value("SELECT body FROM message_search_index WHERE rowid = #{message.id}")
      true
    end

    ActiveSupport::Notifications.subscribed(collect, "sql.active_record") do
      room.messages.create!(creator: users(:david), body: "<p>One native commit</p>")
    end

    assert_equal 1, sql.count { |statement| statement.match?(/\ACOMMIT\b/i) }
    commit = sql.index { |statement| statement.match?(/\ACOMMIT\b/i) }
    assert_operator sql.index { |statement| statement.match?(/insert into message_search_index/i) }, :<, commit
    assert_operator sql.index { |statement| statement.match?(/UPDATE "memberships"/i) }, :<, commit
  end
end
