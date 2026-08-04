require "test_helper"
require "tmpdir"
require Rails.root.join("db/migrate/20260803000000_bind_transfer_intents_to_authorization").to_s

class BindTransferIntentsToAuthorizationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PREVIOUS_SCHEMA_VERSION = 20260802010000

  test "revokes existing transfer intents and requires authorization binding" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_user(connection)
      insert_intent(connection, id: 1, purpose: "join", token: "a", credential: "b")
      insert_intent(connection, id: 2, purpose: "transfer_grant", token: "c", user_id: 1)
      insert_intent(connection, id: 3, purpose: "transfer", token: "d", user_id: 1)

      context.up

      assert_equal [ [ 1, "join" ] ], connection.select_rows(
        "SELECT id, purpose FROM credential_intents ORDER BY id"
      )
      assert_raises(ActiveRecord::StatementInvalid) do
        insert_intent(connection, id: 4, purpose: "transfer", token: "e", user_id: 1)
      end
      insert_intent(connection, id: 4, purpose: "transfer", token: "e", credential: "f", user_id: 1)
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "rollback restores the previous nullable transfer contract" do
    with_temporary_database do |connection, context|
      context.up
      insert_user(connection)
      insert_intent(connection, id: 1, purpose: "transfer", token: "a", credential: "b", user_id: 1)

      context.down(PREVIOUS_SCHEMA_VERSION)

      assert_nil connection.select_value("SELECT credential_digest FROM credential_intents WHERE id = 1")
      insert_intent(connection, id: 2, purpose: "transfer_grant", token: "c", user_id: 1)
      assert_raises(ActiveRecord::StatementInvalid) do
        insert_intent(connection, id: 3, purpose: "transfer", token: "d", credential: "e", user_id: 1)
      end
    end
  end

  private
    def with_temporary_database
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-transfer-intent-migration") do |directory|
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3", database: File.join(directory, "migration.sqlite3")
        )
        yield ActiveRecord::Base.connection, ActiveRecord::Base.connection_pool.migration_context
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config)
    end

    def insert_user(connection)
      connection.execute <<~SQL
        INSERT INTO users (id, name, password_digest, created_at, updated_at)
        VALUES (1, 'Transfer User', 'password-digest', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def insert_intent(connection, id:, purpose:, token:, credential: nil, user_id: nil)
      connection.execute <<~SQL
        INSERT INTO credential_intents
          (id, purpose, token_digest, credential_digest, user_id, expires_at, created_at, updated_at)
        VALUES
          (#{id}, #{connection.quote(purpose)}, #{connection.quote(token * 64)},
           #{connection.quote(credential && credential * 64)}, #{connection.quote(user_id)},
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
end
