require "test_helper"
require "tmpdir"
require Rails.root.join(
  "db/migrate/20260804000000_add_identity_deprovisionings_and_oidc_session_generations"
).to_s

class AddIdentityDeprovisioningsAndOidcSessionGenerationsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PREVIOUS_SCHEMA_VERSION = 20260803000000

  test "retires existing OIDC sessions and installs durable security storage" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_identity_and_sessions(connection)

      context.up

      assert_equal 0, connection.select_value(
        "SELECT COUNT(*) FROM sessions WHERE authentication_method = 'oidc'"
      ).to_i
      assert_equal 1, connection.select_value(
        "SELECT COUNT(*) FROM sessions WHERE authentication_method = 'password'"
      ).to_i
      assert connection.data_source_exists?(:identity_deprovisionings)
      assert connection.column_exists?(:accounts, :oidc_session_generation)
      assert connection.column_exists?(:sessions, :oidc_session_generation)
      assert_equal 1, connection.select_value(<<~SQL).to_i
        SELECT COUNT(*) FROM identity_deprovisionings
        WHERE issuer = 'https://idp.example.com' AND subject = 'migration-subject'
      SQL
      assert_empty connection.exec_query("PRAGMA foreign_key_check")

      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute <<~SQL
          INSERT INTO sessions
            (user_id, identity_id, authentication_method, oidc_configuration_fingerprint,
             oidc_issued_at, expires_at, token, last_active_at, created_at, updated_at)
          VALUES
            (1, 1, 'oidc', '#{'b' * 64}', 1, CURRENT_TIMESTAMP, 'missing-generation',
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end


      connection.execute <<~SQL
        INSERT INTO identity_deprovisionings
          (issuer, subject, deprovisioned_at, created_at, updated_at)
        VALUES
          ('https://idp.example.com', 'durable-subject', CURRENT_TIMESTAMP,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO sessions
          (id, user_id, identity_id, authentication_method, oidc_configuration_fingerprint,
           oidc_session_generation, oidc_issued_at, expires_at, token, last_active_at,
           created_at, updated_at)
        VALUES
          (3, 1, 1, 'oidc', '#{'b' * 64}', 1, 1, CURRENT_TIMESTAMP, 'current-generation',
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL

      AddIdentityDeprovisioningsAndOidcSessionGenerations.new.migrate(:up)

      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM sessions WHERE id = 3").to_i
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM identity_deprovisionings").to_i
    end
  end

  test "migration and checked-in schema expose the same contract" do
    migrated_contract = nil
    with_temporary_database do |connection, context|
      context.up
      migrated_contract = security_contract(connection)
    end

    with_temporary_database do |connection, _context|
      load Rails.root.join("db/schema.rb")
      assert_equal migrated_contract, security_contract(connection)
    end
  end

  test "rollback cannot discard tombstones or retired generations" do
    with_temporary_database do |_connection, context|
      context.up

      error = assert_raises(StandardError) do
        context.down(PREVIOUS_SCHEMA_VERSION)
      end

      assert_match(/security records/, error.message)
    end
  end

  private
    def with_temporary_database
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-identity-security-migration") do |directory|
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3", database: File.join(directory, "migration.sqlite3")
        )
        yield ActiveRecord::Base.connection, ActiveRecord::Base.connection_pool.migration_context
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config)
    end

    def insert_identity_and_sessions(connection)
      connection.execute <<~SQL
        INSERT INTO users (id, name, password_digest, role, status, created_at, updated_at)
        VALUES (1, 'Federated User', 'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO identities
          (id, user_id, issuer, subject, provider_fingerprint, scim_id, provider_revoked_at, provisioned,
           created_at, updated_at)
        VALUES
          (1, 1, 'https://idp.example.com', 'migration-subject', '#{'a' * 64}',
           '11111111-1111-1111-1111-111111111111', CURRENT_TIMESTAMP, 0,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO sessions
          (id, user_id, identity_id, authentication_method, oidc_configuration_fingerprint,
           oidc_issued_at, expires_at, token, last_active_at, created_at, updated_at)
        VALUES
          (1, 1, 1, 'oidc', '#{'b' * 64}', 1, CURRENT_TIMESTAMP, 'oidc-session',
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 1, NULL, 'password', NULL, NULL, NULL, 'local-session',
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def security_contract(connection)
      {
        account_columns: connection.columns(:accounts).to_h { [ _1.name, [ _1.type, _1.null, _1.default ] ] }
          .slice("oidc_session_configuration_fingerprint", "oidc_session_generation"),
        account_checks: connection.check_constraints(:accounts).to_h { [ _1.name, _1.expression ] }
          .slice("accounts_oidc_session_configuration_fingerprint", "accounts_oidc_session_generation"),
        session_column: connection.columns(:sessions).to_h { [ _1.name, [ _1.type, _1.null ] ] }
          .slice("oidc_session_generation"),
        session_checks: connection.check_constraints(:sessions).to_h { [ _1.name, _1.expression ] }
          .slice("sessions_oidc_generation_method"),
        identity_checks: connection.check_constraints(:identities).to_h { [ _1.name, _1.expression ] }
          .slice("identities_reserved_scim_id"),
        deprovisioning_columns: connection.columns(:identity_deprovisionings)
          .to_h { [ _1.name, [ _1.type, _1.null ] ] },
        deprovisioning_indexes: connection.indexes(:identity_deprovisionings).map do |index|
          [ index.columns, index.unique, index.where ]
        end,
        deprovisioning_checks: connection.check_constraints(:identity_deprovisionings)
          .to_h { [ _1.name, _1.expression ] }
      }
    end
end
