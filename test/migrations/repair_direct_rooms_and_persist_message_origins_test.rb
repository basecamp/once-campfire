require "test_helper"
require "tmpdir"

class RepairDirectRoomsAndPersistMessageOriginsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PREVIOUS_SCHEMA_VERSION = 20260804000000
  MIGRATION_VERSION = 20260805000000

  test "upgrade from 20260804 repairs null direct keys and persists origins" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_20260804_records(connection)

      context.up(MIGRATION_VERSION)

      keys = connection.select_values(<<~SQL)
        SELECT direct_participant_key FROM rooms
        WHERE type = 'Rooms::Direct' ORDER BY id
      SQL
      assert_equal 2, keys.compact.uniq.size
      assert_equal "v1:#{Digest::SHA256.hexdigest("1:2")}", keys.first
      assert keys.second.start_with?("legacy:repair:2:")
      assert_equal "user", connection.select_value("SELECT origin FROM messages WHERE id = 1")
      assert_equal "user", connection.columns(:messages).find { _1.name == "origin" }.default

      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute "UPDATE rooms SET direct_participant_key = NULL WHERE id = 2"
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute "UPDATE rooms SET direct_participant_key = 'shared-key' WHERE id = 3"
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute "UPDATE messages SET origin = 'unknown' WHERE id = 1"
      end
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "migration and checked-in schema expose the same repaired contract" do
    migrated_contract = nil
    with_temporary_database do |connection, context|
      context.up(MIGRATION_VERSION)
      migrated_contract = repaired_contract(connection)
    end

    with_temporary_database do |connection, _context|
      load Rails.root.join("db/schema.rb")
      assert_equal migrated_contract, repaired_contract(connection)
    end
  end

  private
    def with_temporary_database
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-messaging-repair-migration") do |directory|
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3", database: File.join(directory, "migration.sqlite3")
        )
        yield ActiveRecord::Base.connection, ActiveRecord::Base.connection_pool.migration_context
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config)
    end

    def insert_20260804_records(connection)
      migration = Class.new(ActiveRecord::Migration[8.2]).new
      migration.remove_check_constraint :rooms, name: "rooms_direct_participant_key_type"
      migration.add_check_constraint :rooms,
        "type = 'Rooms::Direct' OR direct_participant_key IS NULL",
        name: "rooms_direct_participant_key_type"
      connection.execute <<~SQL
        INSERT INTO users
          (id, name, role, status, created_at, updated_at)
        VALUES
          (1, 'First User', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 'Second User', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      canonical_key = "v1:#{Digest::SHA256.hexdigest("1:2")}"
      connection.execute <<~SQL
        INSERT INTO rooms
          (id, name, type, creator_id, direct_participant_key, created_at, updated_at)
        VALUES
          (1, NULL, 'Rooms::Direct', 1, #{connection.quote(canonical_key)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, NULL, 'Rooms::Direct', 1, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (3, 'Shared', 'Rooms::Closed', 1, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO memberships
          (room_id, user_id, involvement, created_at, updated_at)
        VALUES
          (1, 1, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (1, 2, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 1, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 2, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (3, 1, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO messages
          (id, room_id, creator_id, client_message_id, created_at, updated_at)
        VALUES
          (1, 3, 1, 'legacy-origin', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def repaired_contract(connection)
      {
        schema_version: connection.select_value("SELECT MAX(version) FROM schema_migrations").to_i,
        room_checks: connection.check_constraints(:rooms).to_h { [ _1.name, _1.expression ] }
          .slice("rooms_direct_participant_key_type"),
        message_origin: connection.columns(:messages).to_h { [ _1.name, [ _1.type, _1.null, _1.default ] ] }
          .slice("origin"),
        message_checks: connection.check_constraints(:messages).to_h { [ _1.name, _1.expression ] }
          .slice("messages_origin")
      }
    end
end
