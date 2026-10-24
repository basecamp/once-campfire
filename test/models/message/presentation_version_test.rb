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

  private
    def sql(statement, *binds)
      connection = Message.connection
      connection.execute(statement.gsub("?") { connection.quote(binds.shift) })
    end

    def now
      Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    end

    def assert_moves(message)
      before = message.reload.presentation_version
      yield
      after = message.reload.presentation_version
      assert after > before, "presentation_version stayed at #{before}"
      assert_equal "#{Message::PRESENTATION}.#{after}", message.cache_version
    end
end
