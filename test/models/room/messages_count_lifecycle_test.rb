require "test_helper"
require "sqlite3"

# Destructive trigger DDL and foreign connections need their own file so parallel
# workers (and transactional tests in messages_count_test) keep a stable trigger set.
class Room::MessagesCountLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Room::MessagesCount.ensure!
    @room = rooms(:designers)
    @other_room = rooms(:pets)
    Room::MessagesCount.backfill!
    @room.reload
    @other_room.reload
  end

  teardown do
    Message.where("client_message_id LIKE ?", "count-%").delete_all
    Room::MessagesCount.ensure!
    Room::MessagesCount.backfill!
  end

  test "ensure! installs missing triggers without changing existing counts" do
    before = @room.reload.messages_count
    Room::MessagesCount.uninstall!

    assert_not Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, Room::MessagesCount::INSERT_TRIGGER)

    Room::MessagesCount.ensure!

    assert Room::MessagesCount::TRIGGERS.all? { |name|
      Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, name)
    }
    assert_equal before, @room.reload.messages_count

    assert_difference -> { @room.reload.messages_count }, +1 do
      @room.messages.create!(creator: users(:jason), body: "After ensure", client_message_id: "count-ensure")
    end
  end

  test "ensure! repairs a partial trigger install" do
    Room::MessagesCount.uninstall!
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TRIGGER #{Room::MessagesCount::INSERT_TRIGGER} AFTER INSERT ON messages
      BEGIN
        UPDATE rooms SET messages_count = messages_count + 1 WHERE id = NEW.room_id;
      END
    SQL

    assert Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, Room::MessagesCount::INSERT_TRIGGER)
    assert_not Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, Room::MessagesCount::DELETE_TRIGGER)

    Room::MessagesCount.ensure!

    assert Room::MessagesCount::TRIGGERS.all? { |name|
      Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, name)
    }
  end

  test "foreign SQLite connections keep the counter in step" do
    path = File.expand_path(ActiveRecord::Base.connection_db_config.database)
    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    before = @room.reload.messages_count
    other_before = @other_room.reload.messages_count

    ActiveRecord::Base.connection_pool.release_connection

    SQLite3::Database.new(path) do |db|
      db.busy_timeout = 5_000
      db.execute(
        "INSERT INTO messages (room_id, creator_id, client_message_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        [ @room.id, users(:david).id, "count-foreign-insert", now, now ]
      )
    end

    assert_equal before + 1, @room.reload.messages_count
    assert_equal @room.messages.count, @room.messages_count

    foreign_id = Message.find_by!(client_message_id: "count-foreign-insert").id

    ActiveRecord::Base.connection_pool.release_connection

    SQLite3::Database.new(path) do |db|
      db.busy_timeout = 5_000
      db.execute("UPDATE messages SET room_id = ? WHERE id = ?", [ @other_room.id, foreign_id ])
    end

    assert_equal before, @room.reload.messages_count
    assert_equal other_before + 1, @other_room.reload.messages_count

    ActiveRecord::Base.connection_pool.release_connection

    SQLite3::Database.new(path) do |db|
      db.busy_timeout = 5_000
      db.execute("DELETE FROM messages WHERE id = ?", [ foreign_id ])
    end

    assert_equal before, @room.reload.messages_count
    assert_equal other_before, @other_room.reload.messages_count
  end
end
