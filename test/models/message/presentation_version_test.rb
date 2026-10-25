require "test_helper"

# The triggers move a message's presentation version for any writer, so raw SQL
# stands in for foreign connections here: none of it runs Rails callbacks.
class Message::PresentationVersionTest < ActiveSupport::TestCase
  setup do
    @message = messages(:first)
    @others = Message.where.not(id: @message.id).where.not(presentation_version: nil).pluck(:id, :presentation_version).to_h
  end

  test "editing the body moves the version" do
    assert_moves(@message) { sql "UPDATE action_text_rich_texts SET body = 'edited' WHERE record_type = 'Message' AND record_id = ?", @message.id }
  end

  test "boosting and unboosting move the version" do
    assert_moves(@message) { sql "INSERT INTO boosts (message_id, booster_id, content, created_at, updated_at) VALUES (?, ?, '🎉', ?, ?)", @message.id, users(:kevin).id, now, now }
    assert_moves(@message) { sql "DELETE FROM boosts WHERE message_id = ? AND booster_id = ?", @message.id, users(:kevin).id }
  end

  test "renaming the creator or a booster moves their messages" do
    assert_moves(@message) { sql "UPDATE users SET name = 'Renamed' WHERE id = ?", @message.creator_id }
    boosted = boosts(:thirteenth).message
    assert_moves(boosted) { sql "UPDATE users SET name = 'Renamed booster' WHERE id = ?", boosts(:thirteenth).booster_id }
  end

  test "renaming the room moves its messages, but posting in it does not" do
    assert_moves(@message) { sql "UPDATE rooms SET name = 'Renamed room' WHERE id = ?", @message.room_id }
    before = @message.reload.presentation_version
    sql "UPDATE rooms SET updated_at = ?, messages_count = messages_count + 1 WHERE id = ?", now, @message.room_id
    assert_equal before, @message.reload.presentation_version
  end

  test "updating the message row moves the version" do
    assert_moves(@message) { sql "UPDATE messages SET updated_at = ? WHERE id = ?", "2099-01-01 00:00:00", @message.id }
  end

  test "a change to one message leaves the others alone" do
    sql "UPDATE action_text_rich_texts SET body = 'edited' WHERE record_type = 'Message' AND record_id = ?", @message.id
    assert_equal @others, Message.where(id: @others.keys).pluck(:id, :presentation_version).to_h
  end

  test "messages with attachments, embedded attachments or in direct rooms are not versioned" do
    sql "INSERT INTO active_storage_blobs (key, filename, content_type, byte_size, checksum, service_name, created_at) VALUES ('presentation-version', 'moon.jpg', 'image/jpeg', 1, 'x', 'test', ?)", now
    blob_id = Message.connection.select_value("SELECT id FROM active_storage_blobs WHERE key = 'presentation-version'")
    sql "INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at) VALUES ('attachment', 'Message', ?, ?, ?)", @message.id, blob_id, now
    assert_nil @message.reload.presentation_version

    embedded = messages(:second)
    sql "UPDATE action_text_rich_texts SET body = '<action-text-attachment sgid=\"x\"></action-text-attachment>' WHERE record_type = 'Message' AND record_id = ?", embedded.id
    assert_nil embedded.reload.presentation_version

    direct = rooms(:david_and_jason).messages.create!(creator: users(:david), body: "Hi", client_message_id: "direct")
    assert_nil direct.reload.presentation_version
  end

  test "an unversioned message keeps Rails' own cache version" do
    sql "UPDATE messages SET presentation_version = NULL WHERE id = ?", @message.id
    @message.reload
    assert_not @message.presentation_versioned?
    assert_not @message.cache_version.to_s.start_with?("#{Message::PRESENTATION}.")
  end

  test "updating an unversioned message with recursive triggers on stays unversioned" do
    sql "UPDATE messages SET presentation_version = NULL WHERE id = ?", @message.id
    with_recursive_triggers do
      sql "UPDATE messages SET updated_at = ? WHERE id = ?", "2099-01-01 00:00:00", @message.id
    end
    assert_nil @message.reload.presentation_version
  end

  test "replacing a message row never reuses one of its versions" do
    assert_moves(@message) { sql "UPDATE messages SET updated_at = ? WHERE id = ?", "2099-01-01 00:00:00", @message.id }
    used = @message.reload.presentation_version
    with_recursive_triggers do
      sql "INSERT OR REPLACE INTO messages (id, room_id, creator_id, client_message_id, created_at, updated_at) VALUES (?, ?, ?, 'replaced', ?, ?)",
        @message.id, @message.room_id, @message.creator_id, now, now
    end
    assert @message.reload.presentation_version > used, "the replaced row restarted at #{@message.presentation_version}"
  end

  test "repairing the triggers advances versions and keeps opt-outs" do
    unversioned = messages(:second)
    sql "UPDATE messages SET presentation_version = NULL WHERE id = ?", unversioned.id
    sql "DROP TRIGGER messages_au_presentation_version"
    assert_moves(@message) { Message::PresentationVersion.ensure! }
    assert_nil unversioned.reload.presentation_version
  end

  test "moving a message into a direct room stops versioning it" do
    sql "UPDATE messages SET room_id = ? WHERE id = ?", rooms(:david_and_jason).id, @message.id
    assert_nil @message.reload.presentation_version
  end

  test "moving a body to another message moves the version of both" do
    other = messages(:third)
    sql "DELETE FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?", other.id
    assert_moves(@message, other) { sql "UPDATE action_text_rich_texts SET record_id = ? WHERE record_type = 'Message' AND record_id = ?", other.id, @message.id }
    assert_moves(other) { sql "UPDATE action_text_rich_texts SET name = 'draft' WHERE record_type = 'Message' AND record_id = ?", other.id }
  end

  test "moving an attachment stops versioning its new message and moves avatars' messages" do
    blob_id = insert_blob("moved")
    sql "INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at) VALUES ('avatar', 'User', ?, ?, ?)", users(:kevin).id, blob_id, now
    assert_moves(@message) { sql "UPDATE active_storage_attachments SET record_id = ? WHERE blob_id = ?", @message.creator_id, blob_id }

    sql "UPDATE active_storage_attachments SET name = 'attachment', record_type = 'Message', record_id = ? WHERE blob_id = ?", @message.id, blob_id
    assert_nil @message.reload.presentation_version
  end

  private
    def insert_blob(key)
      sql "INSERT INTO active_storage_blobs (key, filename, content_type, byte_size, checksum, service_name, created_at) VALUES (?, 'moon.jpg', 'image/jpeg', 1, 'x', 'test', ?)", key, now
      Message.connection.select_value("SELECT id FROM active_storage_blobs WHERE key = #{Message.connection.quote(key)}")
    end

    def with_recursive_triggers
      sql "PRAGMA recursive_triggers = ON"
      yield
    ensure
      sql "PRAGMA recursive_triggers = OFF"
    end

    def sql(statement, *binds)
      connection = Message.connection
      connection.execute(statement.gsub("?") { connection.quote(binds.shift) })
    end

    def now
      Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    end

    def assert_moves(*messages)
      before = messages.map { |message| message.reload.presentation_version }
      yield
      messages.zip(before).each do |message, version|
        after = message.reload.presentation_version
        assert after > version, "message #{message.id}'s presentation_version stayed at #{version}"
        assert_equal "#{Message::PRESENTATION}.#{after}", message.cache_version
      end
    end
end
