require "test_helper"
require "sqlite3"

class Room::MessagesCountTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @other_room = rooms(:pets)
    synchronize!(@room, @other_room)
  end

  test "ActiveRecord create and destroy adjust the counter once" do
    assert_difference -> { @room.reload.messages_count }, +1 do
      assert_difference -> { @room.messages.count }, +1 do
        @room.messages.create!(creator: users(:jason), body: "Hello", client_message_id: "count-ar-create")
      end
    end

    assert_equal @room.messages.count, @room.reload.messages_count

    assert_difference -> { @room.reload.messages_count }, -1 do
      assert_difference -> { @room.messages.count }, -1 do
        @room.messages.order(:id).last.destroy
      end
    end

    assert_equal @room.messages.count, @room.reload.messages_count
  end

  test "bulk insert_all and delete_all keep the counter in step" do
    rows = Array.new(3) do |i|
      {
        room_id: @room.id,
        creator_id: users(:david).id,
        client_message_id: "count-bulk-#{i}",
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    assert_difference -> { @room.reload.messages_count }, +3 do
      Message.insert_all!(rows)
    end

    assert_equal @room.messages.count, @room.reload.messages_count

    assert_difference -> { @room.reload.messages_count }, -3 do
      @room.messages.where(client_message_id: rows.map { it[:client_message_id] }).delete_all
    end

    assert_equal @room.messages.count, @room.reload.messages_count
  end

  test "rolled back writes leave the counter unchanged" do
    before = @room.reload.messages_count

    Message.transaction do
      @room.messages.create!(creator: users(:jason), body: "Nope", client_message_id: "count-rollback")
      raise ActiveRecord::Rollback
    end

    assert_equal before, @room.reload.messages_count
    assert_nil Message.find_by(client_message_id: "count-rollback")
  end

  test "moving a message between rooms moves the counter" do
    message = @room.messages.create!(creator: users(:jason), body: "Move me", client_message_id: "count-move")
    synchronize!(@room, @other_room)

    assert_difference -> { @room.reload.messages_count }, -1 do
      assert_difference -> { @other_room.reload.messages_count }, +1 do
        message.update!(room: @other_room)
      end
    end

    assert_equal @room.messages.count, @room.reload.messages_count
    assert_equal @other_room.messages.count, @other_room.reload.messages_count
  end

  test "ensure! installs missing triggers without changing existing counts" do
    before = @room.reload.messages_count
    Room::MessagesCount.uninstall!

    assert_not Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, Room::MessagesCount::INSERT_TRIGGER)

    Room::MessagesCount.ensure!

    assert Room::MessagesCount.trigger_installed?(ActiveRecord::Base.connection, Room::MessagesCount::INSERT_TRIGGER)
    assert_equal before, @room.reload.messages_count

    assert_difference -> { @room.reload.messages_count }, +1 do
      @room.messages.create!(creator: users(:jason), body: "After ensure", client_message_id: "count-ensure")
    end
  ensure
    Room::MessagesCount.ensure!
  end

  test "backfill plus triggers do not double-count ActiveRecord writes" do
    Room::MessagesCount.uninstall!
    ActiveRecord::Base.connection.execute <<~SQL
      UPDATE rooms SET messages_count = (
        SELECT COUNT(*) FROM messages WHERE messages.room_id = rooms.id
      )
    SQL
    Room::MessagesCount.install!

    assert_equal @room.messages.count, @room.reload.messages_count

    assert_difference -> { @room.reload.messages_count }, +1 do
      assert_difference -> { @room.messages.count }, +1 do
        @room.messages.create!(creator: users(:jason), body: "Once", client_message_id: "count-no-double")
      end
    end

    assert_equal @room.messages.count, @room.reload.messages_count
  ensure
    Room::MessagesCount.ensure!
  end

  private
    def synchronize!(*rooms)
      Room::MessagesCount.ensure!
      Room::MessagesCount.backfill!
      rooms.each(&:reload)
    end
end

# Foreign connections cannot join the transactional fixture lock; run outside it.
class Room::MessagesCountForeignConnectionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Room::MessagesCount.ensure!
    @room = rooms(:designers)
    Room::MessagesCount.backfill!
    @room.reload
  end

  teardown do
    Message.where(client_message_id: "count-foreign-insert").delete_all
    Room::MessagesCount.backfill!
  end

  test "foreign SQLite connections keep the counter in step" do
    path = File.expand_path(ActiveRecord::Base.connection_db_config.database)
    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    before = @room.reload.messages_count

    # Release AR's checkout so the native connection can write.
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
      db.execute("DELETE FROM messages WHERE id = ?", [ foreign_id ])
    end

    assert_equal before, @room.reload.messages_count
    assert_equal @room.messages.count, @room.messages_count
  end
end
