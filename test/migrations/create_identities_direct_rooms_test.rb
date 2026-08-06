require "test_helper"
require "tmpdir"

class CreateIdentitiesDirectRoomsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PREVIOUS_SCHEMA_VERSION = 20251212154340
  MIGRATION_VERSION = 20260730000000

  test "upgrade gives every duplicate legacy room an immutable unique identity" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_duplicate_direct_rooms(connection)

      context.up(MIGRATION_VERSION)

      keys = connection.select_values("SELECT direct_participant_key FROM rooms ORDER BY id")
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM rooms").to_i
      assert_equal "v1:#{Digest::SHA256.hexdigest("1:2")}", keys.first
      assert keys.second.start_with?("legacy:2:")
      assert_equal 2, keys.compact.uniq.size
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute <<~SQL
          UPDATE rooms SET direct_participant_key = #{connection.quote(keys.first)} WHERE id = 2
        SQL
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute "UPDATE rooms SET direct_participant_key = NULL WHERE id = 2"
      end
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "rollback removes only canonical identity metadata" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_duplicate_direct_rooms(connection)
      context.up(MIGRATION_VERSION)

      context.down(PREVIOUS_SCHEMA_VERSION)

      assert_not connection.column_exists?(:rooms, :direct_participant_key)
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM rooms").to_i
      assert_equal 4, connection.select_value("SELECT COUNT(*) FROM memberships").to_i
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  private
    def with_temporary_database
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-direct-room-migration") do |directory|
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(directory, "migration.sqlite3"))
        yield ActiveRecord::Base.connection, ActiveRecord::Base.connection_pool.migration_context
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config)
    end

    def insert_duplicate_direct_rooms(connection)
      connection.execute <<~SQL
        INSERT INTO users
          (id, name, email_address, password_digest, role, status, created_at, updated_at)
        VALUES
          (1, 'First User', 'first@example.com', 'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 'Second User', 'second@example.com', 'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO rooms
          (id, name, type, creator_id, created_at, updated_at)
        VALUES
          (1, NULL, 'Rooms::Direct', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, NULL, 'Rooms::Direct', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO memberships
          (room_id, user_id, involvement, created_at, updated_at)
        VALUES
          (1, 1, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (1, 2, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 1, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 2, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
end
