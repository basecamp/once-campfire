require "test_helper"
require "tmpdir"
require Rails.root.join("db/migrate/20260802010000_add_identity_provider_revocation").to_s

class AddIdentityProviderRevocationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PREVIOUS_SCHEMA_VERSION = 20260802000000

  test "backfills stable SCIM ids and expires OIDC sessions without signed provider provenance" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_identity_sessions_and_push_subscriptions(connection)

      context.up

      identity = connection.select_one("SELECT * FROM identities WHERE id = 1")
      local_session = connection.select_one("SELECT * FROM sessions WHERE id = 2")
      assert_match Identity::SCIM_ID_PATTERN, identity.fetch("scim_id")
      assert_nil identity.fetch("provider_revoked_at")
      assert_nil local_session.fetch("oidc_session_id")
      assert_nil local_session.fetch("oidc_issued_at")
      assert_equal 0, connection.select_value("SELECT COUNT(*) FROM sessions WHERE id = 1").to_i
      assert_equal 0, connection.select_value(
        "SELECT COUNT(*) FROM push_subscriptions WHERE session_id = 1"
      ).to_i
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM sessions WHERE id = 2").to_i
      assert_equal 1, connection.select_value(
        "SELECT COUNT(*) FROM push_subscriptions WHERE session_id = 2"
      ).to_i
      assert connection.data_source_exists?("oidc_logout_tokens")
      assert connection.data_source_exists?("oidc_revocations")
      assert_empty connection.exec_query("PRAGMA foreign_key_check")

      insert_current_oidc_session_and_push_subscription(connection)

      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("UPDATE identities SET scim_id = '#{'A' * 36}' WHERE id = 1")
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("UPDATE sessions SET oidc_session_id = '#{'x' * 256}' WHERE id = 3")
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("UPDATE sessions SET oidc_issued_at = NULL WHERE id = 3")
      end
    end
  end

  test "migration is re-entrant and preserves previously assigned identifiers" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_identity_sessions_and_push_subscriptions(connection)
      context.up
      scim_id = connection.select_value("SELECT scim_id FROM identities WHERE id = 1")
      insert_current_oidc_session_and_push_subscription(connection)

      AddIdentityProviderRevocation.new.migrate(:up)

      assert_equal scim_id, connection.select_value("SELECT scim_id FROM identities WHERE id = 1")
      assert_equal 0, connection.select_value("SELECT COUNT(*) FROM sessions WHERE id = 1").to_i
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM sessions WHERE id IN (2, 3)").to_i
      assert_equal 2, connection.select_value(
        "SELECT COUNT(*) FROM push_subscriptions WHERE session_id IN (2, 3)"
      ).to_i
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "a mid-migration failure rolls every schema and data change back atomically" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_identity_sessions_and_push_subscriptions(connection)
      failing_migration = Class.new(AddIdentityProviderRevocation) do
        private
          def add_session_revocation_columns
            super
            raise "simulated migration crash"
          end
      end.new

      assert_raises(RuntimeError) { failing_migration.migrate(:up) }

      assert_not connection.column_exists?(:identities, :scim_id)
      assert_not connection.column_exists?(:identities, :provider_revoked_at)
      assert_not connection.column_exists?(:sessions, :oidc_session_id)
      assert_not connection.column_exists?(:sessions, :oidc_issued_at)
      assert_not connection.data_source_exists?("oidc_logout_tokens")
      assert_not connection.data_source_exists?("oidc_revocations")
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM identities WHERE id = 1").to_i
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM sessions WHERE id IN (1, 2)").to_i
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM push_subscriptions").to_i
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "migration and checked-in schema have the same revocation contract" do
    migrated_contract = nil
    with_temporary_database do |connection, context|
      context.up
      migrated_contract = revocation_contract(connection)
    end

    with_temporary_database do |connection, _context|
      load Rails.root.join("db/schema.rb")
      assert_equal migrated_contract, revocation_contract(connection)
    end
  end

  test "rollback is explicitly non-destructive and leaves all security records intact" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_identity_sessions_and_push_subscriptions(connection)
      context.up
      insert_current_oidc_session_and_push_subscription(connection)
      connection.execute("UPDATE identities SET provider_revoked_at = CURRENT_TIMESTAMP WHERE id = 1")
      connection.execute <<~SQL
        INSERT INTO oidc_revocations
          (issuer_fingerprint, identifier_type, identifier_digest, revoked_before, expires_at,
           created_at, updated_at)
        VALUES
          ('#{'a' * 64}', 'sub', '#{'b' * 64}', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL

      error = assert_raises(StandardError) { context.down(PREVIOUS_SCHEMA_VERSION) }

      assert_match(/security records|provider revocations/, error.message)
      assert connection.column_exists?(:identities, :provider_revoked_at)
      assert connection.column_exists?(:sessions, :oidc_issued_at)
      assert connection.data_source_exists?("oidc_revocations")
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM identities WHERE id = 1").to_i
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM sessions WHERE id IN (2, 3)").to_i
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM push_subscriptions").to_i
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM oidc_revocations").to_i
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  private
    def with_temporary_database
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-provider-revocation-migration") do |directory|
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3", database: File.join(directory, "migration.sqlite3")
        )
        yield ActiveRecord::Base.connection, ActiveRecord::Base.connection_pool.migration_context
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config)
    end

    def insert_identity_sessions_and_push_subscriptions(connection)
      connection.execute <<~SQL
        INSERT INTO users (id, name, password_digest, role, status, created_at, updated_at)
        VALUES (1, 'Federated User', 'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO identities
          (id, user_id, issuer, subject, provider_fingerprint, provisioned, created_at, updated_at)
        VALUES
          (1, 1, 'https://idp.example.com', 'migration-subject', '#{'a' * 64}', 0,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO sessions
          (id, user_id, identity_id, authentication_method, oidc_configuration_fingerprint,
           expires_at, token, last_active_at, created_at, updated_at)
        VALUES
          (1, 1, 1, 'oidc', '#{'b' * 64}', CURRENT_TIMESTAMP, 'migration-session',
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 1, NULL, 'password', NULL, NULL, 'local-migration-session',
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO push_subscriptions
          (id, user_id, session_id, endpoint, p256dh_key, auth_key, created_at, updated_at)
        VALUES
          (1, 1, 1, 'https://push.example/migration', 'key', 'auth', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 1, 2, 'https://push.example/local-migration', 'local-key', 'local-auth',
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def insert_current_oidc_session_and_push_subscription(connection)
      connection.execute <<~SQL
        INSERT INTO sessions
          (id, user_id, identity_id, authentication_method, oidc_configuration_fingerprint,
           oidc_session_id, oidc_issued_at, expires_at, token, last_active_at, created_at, updated_at)
        VALUES
          (3, 1, 1, 'oidc', '#{'b' * 64}', 'signed-provider-session', 1,
           CURRENT_TIMESTAMP, 'current-migration-session', CURRENT_TIMESTAMP,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO push_subscriptions
          (id, user_id, session_id, endpoint, p256dh_key, auth_key, created_at, updated_at)
        VALUES
          (3, 1, 3, 'https://push.example/current-migration', 'current-key', 'current-auth',
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def revocation_contract(connection)
      {
        identity_columns: connection.columns(:identities).to_h { [ _1.name, [ _1.type, _1.null ] ] }
          .slice("scim_id", "provider_revoked_at"),
        identity_indexes: connection.indexes(:identities).filter_map do |index|
          [ index.columns, index.unique, index.where ] if index.columns.include?("scim_id")
        end,
        identity_checks: connection.check_constraints(:identities).to_h { [ _1.name, _1.expression ] }
          .slice("identities_scim_id"),
        session_columns: connection.columns(:sessions).to_h { [ _1.name, [ _1.type, _1.null ] ] }
          .slice("oidc_session_id", "oidc_issued_at"),
        session_indexes: connection.indexes(:sessions).filter_map do |index|
          [ index.columns, index.unique, index.where ] if index.columns.include?("oidc_session_id")
        end,
        session_checks: connection.check_constraints(:sessions).to_h { [ _1.name, _1.expression ] }
          .slice(
            "sessions_oidc_session_id_method", "sessions_oidc_session_id_bytes",
            "sessions_oidc_issued_at_method", "sessions_oidc_issued_at_positive"
          ),
        logout_columns: connection.columns(:oidc_logout_tokens).to_h { [ _1.name, [ _1.type, _1.null ] ] },
        logout_indexes: connection.indexes(:oidc_logout_tokens).map do |index|
          [ index.columns, index.unique, index.where ]
        end.sort,
        revocation_columns: connection.columns(:oidc_revocations).to_h { [ _1.name, [ _1.type, _1.null ] ] },
        revocation_indexes: connection.indexes(:oidc_revocations).map do |index|
          [ index.columns, index.unique, index.where ]
        end.sort,
        revocation_checks: connection.check_constraints(:oidc_revocations).to_h do |constraint|
          [ constraint.name, constraint.expression ]
        end
      }
    end
end
