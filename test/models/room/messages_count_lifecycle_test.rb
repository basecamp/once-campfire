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

  test "ensure! installs missing triggers and keeps accurate counts" do
    before = @room.reload.messages_count
    Room::MessagesCount.uninstall!

    assert_not Room::MessagesCount.triggers_installed?

    Room::MessagesCount.ensure!

    assert Room::MessagesCount.triggers_installed?
    assert_equal before, @room.reload.messages_count
    assert_equal @room.messages.count, @room.messages_count

    assert_difference -> { @room.reload.messages_count }, +1 do
      @room.messages.create!(creator: users(:jason), body: "After ensure", client_message_id: "count-ensure")
    end
  end

  test "ensure! repairs a partial trigger install and backfills drifted counts" do
    Room::MessagesCount.uninstall!
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TRIGGER #{Room::MessagesCount::INSERT_TRIGGER} AFTER INSERT ON messages
      BEGIN
        UPDATE rooms SET messages_count = messages_count + 1 WHERE id = NEW.room_id;
      END
    SQL

    assert Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, Room::MessagesCount::INSERT_TRIGGER)
    assert_not Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, Room::MessagesCount::DELETE_TRIGGER)

    # Delete fires with no delete trigger → counter drifts high.
    drifted = @room.messages.create!(creator: users(:jason), body: "Drift", client_message_id: "count-partial-drift")
    ActiveRecord::Base.connection.execute("DELETE FROM messages WHERE id = #{drifted.id}")
    assert_operator @room.reload.messages_count, :>, @room.messages.count

    Room::MessagesCount.ensure!

    assert Room::MessagesCount.triggers_installed?
    assert_equal @room.messages.count, @room.reload.messages_count
  end

  test "ensure! backfills writes that landed while the insert trigger was missing" do
    Room::MessagesCount.uninstall!
    before_count = @room.messages.count
    before_cached = @room.reload.messages_count
    assert_equal before_count, before_cached

    path = File.expand_path(ActiveRecord::Base.connection_db_config.database)
    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    ActiveRecord::Base.connection_pool.release_connection

    SQLite3::Database.new(path) do |db|
      db.busy_timeout = 5_000
      db.execute(
        "INSERT INTO messages (room_id, creator_id, client_message_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        [ @room.id, users(:david).id, "count-missing-insert", now, now ]
      )
    end

    assert_equal before_count + 1, @room.messages.count
    assert_equal before_cached, @room.reload.messages_count

    Room::MessagesCount.ensure!

    assert Room::MessagesCount.triggers_installed?
    assert_equal @room.messages.count, @room.reload.messages_count
    assert_equal before_cached + 1, @room.messages_count
  end

  test "concurrent ensure! repairs leave triggers installed and counts accurate" do
    Room::MessagesCount.uninstall!
    path = File.expand_path(ActiveRecord::Base.connection_db_config.database)
    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    ActiveRecord::Base.connection_pool.release_connection

    SQLite3::Database.new(path) do |db|
      db.busy_timeout = 5_000
      db.execute(
        "INSERT INTO messages (room_id, creator_id, client_message_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        [ @room.id, users(:david).id, "count-concurrent-drift", now, now ]
      )
    end

    assert_not_equal @room.messages.count, @room.reload.messages_count

    errors = []
    errors_mutex = Mutex.new

    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          Room::MessagesCount.ensure!(connection)
        end
      rescue => error
        errors_mutex.synchronize { errors << error }
      end
    end

    workers.each(&:join)

    assert_empty errors, -> { errors.map(&:full_message).join("\n") }
    assert Room::MessagesCount.triggers_installed?
    assert_equal @room.messages.count, @room.reload.messages_count
  end

  test "writes concurrent with ensure! repair leave accurate counts" do
    Room::MessagesCount.uninstall!
    path = File.expand_path(ActiveRecord::Base.connection_db_config.database)
    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    ActiveRecord::Base.connection_pool.release_connection

    errors = []
    errors_mutex = Mutex.new

    ensure_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Room::MessagesCount.ensure!(connection)
      end
    rescue => error
      errors_mutex.synchronize { errors << error }
    end

    insert_thread = Thread.new do
      SQLite3::Database.new(path) do |db|
        db.busy_timeout = 10_000
        db.execute(
          "INSERT INTO messages (room_id, creator_id, client_message_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
          [ @room.id, users(:david).id, "count-during-repair", now, now ]
        )
      end
    rescue => error
      errors_mutex.synchronize { errors << error }
    end

    [ ensure_thread, insert_thread ].each(&:join)

    assert_empty errors, -> { errors.map(&:full_message).join("\n") }
    assert Room::MessagesCount.triggers_installed?
    assert_equal @room.messages.count, @room.reload.messages_count
    assert Message.exists?(client_message_id: "count-during-repair")
  end

  test "install! never exposes a partial trigger set to other connections" do
    Room::MessagesCount.uninstall!
    path = File.expand_path(ActiveRecord::Base.connection_db_config.database)
    ActiveRecord::Base.connection_pool.release_connection

    stop = false
    partial_snapshots = []
    snapshots_mutex = Mutex.new

    watcher = Thread.new do
      SQLite3::Database.new(path) do |db|
        db.busy_timeout = 5_000
        until stop
          names = db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name IN (#{Room::MessagesCount::TRIGGERS.map { "'#{it}'" }.join(", ")})"
          ).flatten
          if names.any? && names.sort != Room::MessagesCount::TRIGGERS.sort
            snapshots_mutex.synchronize { partial_snapshots << names.sort }
          end
        end
      end
    end

    25.times { Room::MessagesCount.install! }
    stop = true
    watcher.join

    assert_empty partial_snapshots
    assert Room::MessagesCount.triggers_installed?
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
