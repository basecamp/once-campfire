require "test_helper"
require "tmpdir"

class CreateIdentitiesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PREVIOUS_SCHEMA_VERSION = 20251212154340
  MIGRATION_VERSION = 20260730000000

  test "upgrades populated legacy data without inventing push session provenance" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_account(connection)
      insert_legacy_user_session_and_push(connection)

      context.up

      session = connection.select_one("SELECT * FROM sessions WHERE token = 'legacy-token'")
      subscription = connection.select_one("SELECT * FROM push_subscriptions WHERE endpoint = 'https://push.example/legacy'")
      assert_equal "legacy", session.fetch("authentication_method")
      assert_nil session.fetch("identity_id")
      assert_nil subscription.fetch("session_id")
      assert_match(/\A[0-9a-f]{32}\z/, connection.select_value("SELECT installation_identifier FROM accounts"))
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("UPDATE accounts SET installation_identifier = '#{'A' * 32}'")
      end
      assert connection.data_source_exists?("message_effects")
      assert connection.data_source_exists?("ban_cleanup_intents")
      assert connection.data_source_exists?("ban_cleanup_blob_entries")
      assert connection.column_exists?(:users, :ban_cleanup_generation)
      assert connection.column_exists?(:message_effects, :lease_token)
      assert connection.column_exists?(:message_effects, :next_attempt_at)
      assert connection.column_exists?(:message_effects, :failed_at)
      assert connection.column_exists?(:ban_cleanup_intents, :purge_started_at)
      assert connection.column_exists?(:ban_cleanup_intents, :message_id_upper_bound)
      assert connection.column_exists?(:ban_cleanup_intents, :blob_id_upper_bound)
      assert connection.column_exists?(:ban_cleanup_intents, :owned_blob_id_cursor)
      assert connection.column_exists?(:ban_cleanup_intents, :snapshot_completed_at)
      session_index = connection.indexes(:push_subscriptions).find { _1.columns == [ "session_id" ] }
      assert session_index.unique
      assert_equal "session_id IS NOT NULL", session_index.where
      assert_not connection.foreign_keys(:message_effects).any? { _1.to_table == "messages" }
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "normalizes legacy emails and adds a unique normalized key" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_user(connection, id: 1, email_address: " Legacy@Example.COM ")
      insert_legacy_user(connection, id: 2, email_address: " JÖRG@Example.COM ")

      context.up

      emails = connection.select_rows(<<~SQL).to_h
        SELECT id, email_address FROM users ORDER BY id
      SQL
      normalized_emails = connection.select_rows(<<~SQL).to_h
        SELECT id, normalized_email_address FROM users ORDER BY id
      SQL
      assert_equal({ 1 => "legacy@example.com", 2 => "jörg@example.com" }, emails.transform_keys(&:to_i))
      assert_equal emails, normalized_emails
      index = connection.indexes(:users).find { _1.name == CreateIdentities::NORMALIZED_EMAIL_INDEX_NAME }
      assert index.unique

      assert_raises ActiveRecord::RecordNotUnique do
        connection.execute <<~SQL
          INSERT INTO users
            (name, email_address, normalized_email_address, password_digest, role, status, created_at, updated_at)
          VALUES
            ('Duplicate', 'LEGACY@example.com', 'legacy@example.com', 'digest', 0, 0,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end
  end

  test "fails closed before changing schema when legacy users have normalization collisions" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_user(connection, id: 1, email_address: "JÖRG@Example.com")
      insert_legacy_user(connection, id: 2, email_address: " jörg@example.COM ")

      error = assert_raises(StandardError) { context.up }

      assert_kind_of ActiveRecord::MigrationError, error.cause
      assert_match "email normalization collision between user ids: 1, 2", error.cause.message
      assert_not connection.column_exists?(:users, :normalized_email_address)
      assert_equal [ "JÖRG@Example.com", " jörg@example.COM " ],
        connection.select_values("SELECT email_address FROM users ORDER BY id")
    end
  end

  test "migration and checked-in schema have the same normalized email contract" do
    migrated_contract = nil
    with_temporary_database do |connection, context|
      context.up
      migrated_contract = normalized_email_contract(connection)
    end

    with_temporary_database do |connection, _context|
      load Rails.root.join("db/schema.rb")
      assert_equal migrated_contract, normalized_email_contract(connection)
    end
  end

  test "backfills legacy banned users with one pending generation-one cleanup intent" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_banned_user_and_message(connection)

      context.up

      user = connection.select_one("SELECT * FROM users WHERE id = 1")
      intent = connection.select_one("SELECT * FROM ban_cleanup_intents WHERE user_id = 1")
      assert_equal 1, user.fetch("ban_cleanup_generation")
      assert_equal 1, intent.fetch("generation")
      assert_equal 0, intent.fetch("attempts")
      assert_nil intent.fetch("lease_token")
      assert_nil intent.fetch("completed_at")
      assert_nil intent.fetch("canceled_at")
      assert_nil intent.fetch("failed_at")
      assert_equal 0, connection.select_value(
        "SELECT COUNT(*) FROM ban_cleanup_intents WHERE user_id = 2"
      ).to_i

      CreateIdentities.new.send(:backfill_legacy_ban_cleanup_intents!)

      assert_equal 1, connection.select_value(
        "SELECT COUNT(*) FROM ban_cleanup_intents WHERE user_id = 1 AND generation = 1"
      ).to_i
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM messages WHERE creator_id = 1").to_i
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "quarantines ambiguous browser capabilities without deleting ownership evidence" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_user_session_and_push(connection)
      connection.execute <<~SQL
        INSERT INTO push_subscriptions
          (user_id, endpoint, p256dh_key, auth_key, created_at, updated_at)
        VALUES
          (1, 'https://push.example/legacy', 'legacy-key', 'legacy-auth', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL

      context.up

      assert connection.data_source_exists?("identities")
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM push_subscriptions").to_i
      assert_equal 0, connection.select_value("SELECT COUNT(*) FROM push_subscriptions WHERE session_id IS NOT NULL").to_i
      assert_not connection.indexes(:push_subscriptions).find { _1.columns == %w[ endpoint p256dh_key auth_key ] }.unique
    end
  end

  test "quarantines a capability when its owner has multiple legacy sessions" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_user_session_and_push(connection)
      connection.execute <<~SQL
        INSERT INTO sessions
          (id, user_id, token, last_active_at, created_at, updated_at)
        VALUES
          (2, 1, 'second-legacy-token', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL

      context.up

      subscription = connection.select_one("SELECT * FROM push_subscriptions WHERE endpoint = 'https://push.example/legacy'")
      assert_nil subscription.fetch("session_id")
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "rekeys room-wide legacy message ID collisions without changing rows or associations" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_account(connection)
      insert_legacy_user_session_and_push(connection)
      insert_legacy_duplicate_messages(connection)

      context.up

      messages = connection.select_rows(
        "SELECT id, client_message_id FROM messages ORDER BY id"
      )
      assert_equal [ 1, 2, 3 ], messages.map { _1.fetch(0) }
      assert_equal "duplicate-message", messages.first.fetch(1)
      assert_not_equal messages.first.fetch(1), messages.second.fetch(1)
      assert_not_equal "__campfire_legacy_duplicate_2", messages.second.fetch(1)
      assert_equal "__campfire_legacy_duplicate_2", messages.third.fetch(1)
      assert_equal 3, connection.select_value("SELECT COUNT(DISTINCT client_message_id) FROM messages").to_i
      assert_equal 2, connection.select_value("SELECT message_id FROM boosts WHERE id = 1").to_i
      index = connection.indexes(:messages).find { _1.name == CreateIdentities::MESSAGE_CLIENT_ID_INDEX_NAME }
      assert_equal %w[ room_id client_message_id ], index.columns
      assert index.unique
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "rekeys oversized legacy message IDs before adding the byte constraint" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_user_session_and_push(connection)
      insert_legacy_message(connection, client_message_id: "x" * 65)

      context.up

      client_message_id = connection.select_value("SELECT client_message_id FROM messages WHERE id = 1")
      assert_operator client_message_id.bytesize, :<=, 64
      assert_not_equal "x" * 65, client_message_id
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("UPDATE messages SET client_message_id = '#{'x' * 65}' WHERE id = 1")
      end
    end
  end

  test "database client message id constraints count bytes and reject without side effects" do
    with_temporary_database do |connection, context|
      context.up
      insert_current_user(connection)
      boundary_id = "\u00E9" * 32
      oversized_id = "#{boundary_id}a"
      connection.execute <<~SQL
        INSERT INTO rooms
          (id, name, type, creator_id, created_at, updated_at)
        VALUES
          (1, 'Current Room', 'Rooms::Open', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO messages
          (id, room_id, creator_id, client_message_id, created_at, updated_at)
        VALUES
          (1, 1, 1, #{connection.quote(boundary_id)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO message_effects
          (message_id, room_id, message_client_id, effect, deduplication_key, attempts, created_at, updated_at)
        VALUES
          (1, 1, #{connection.quote(boundary_id)}, 'broadcast_create', 'boundary', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL

      assert_equal 64, boundary_id.bytesize
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM messages").to_i
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM message_effects").to_i
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute <<~SQL
          INSERT INTO messages
            (id, room_id, creator_id, client_message_id, created_at, updated_at)
          VALUES
            (2, 1, 1, #{connection.quote(oversized_id)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute <<~SQL
          INSERT INTO message_effects
            (message_id, room_id, message_client_id, effect, deduplication_key, attempts, created_at, updated_at)
          VALUES
            (1, 1, #{connection.quote(oversized_id)}, 'broadcast_update', 'oversized', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM messages").to_i
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM message_effects").to_i
    end
  end


  test "rolls an empty current schema back to the previous version" do
    with_temporary_database do |connection, context|
      context.up(MIGRATION_VERSION)

      context.down(PREVIOUS_SCHEMA_VERSION)

      assert_not connection.data_source_exists?("identities")
      assert_not connection.data_source_exists?("message_effects")
      assert_not connection.data_source_exists?("ban_cleanup_blob_entries")
      assert_not connection.data_source_exists?("ban_cleanup_intents")
      assert_not connection.column_exists?(:sessions, :authentication_method)
      assert_not connection.column_exists?(:users, :ban_cleanup_generation)
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "refuses production rollback without separate rollback authorization" do
    with_temporary_database do |connection, context|
      context.up
      previous_environment = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "production"

      error = assert_raises(ActiveRecord::IrreversibleMigration) do
        CreateIdentities.new.down
      end

      assert_match "separately authenticated rollback archive", error.message
      assert connection.data_source_exists?("identities")
      assert connection.column_exists?(:sessions, :authentication_method)
    ensure
      previous_environment ? ENV["RAILS_ENV"] = previous_environment : ENV.delete("RAILS_ENV")
    end
  end

  test "does not destructively roll a schema-loaded current database back" do
    with_temporary_database do |connection, context|
      load Rails.root.join("db/schema.rb")

      error = assert_raises(StandardError) { context.down(PREVIOUS_SCHEMA_VERSION) }

      assert_match(/security records|provider revocations/, error.message)
      assert connection.data_source_exists?("identities")
      assert connection.data_source_exists?("oidc_revocations")
      assert connection.column_exists?(:push_subscriptions, :session_id)
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "round trips populated legacy data through up and down" do
    with_temporary_database do |connection, context|
      context.up(PREVIOUS_SCHEMA_VERSION)
      insert_legacy_user_session_and_push(connection)

      context.up(MIGRATION_VERSION)
      context.down(PREVIOUS_SCHEMA_VERSION)

      assert_equal "legacy-token", connection.select_value("SELECT token FROM sessions WHERE id = 1")
      assert_equal "https://push.example/legacy", connection.select_value("SELECT endpoint FROM push_subscriptions")
      assert connection.column_exists?(:accounts, :installation_identifier)
      assert_empty connection.exec_query("PRAGMA foreign_key_check")
    end
  end

  test "retained additive schema accepts writes from the previous application shape" do
    with_temporary_database do |connection, context|
      context.up
      insert_legacy_user_session_and_push(connection)

      session = connection.select_one("SELECT * FROM sessions WHERE token = 'legacy-token'")
      subscription = connection.select_one("SELECT * FROM push_subscriptions WHERE endpoint = 'https://push.example/legacy'")

      assert_equal "legacy", session.fetch("authentication_method")
      assert_nil session.fetch("oidc_configuration_fingerprint")
      assert_nil subscription.fetch("session_id")
      assert_empty connection.exec_query("PRAGMA foreign_key_check")

      connection.execute <<~SQL
        INSERT INTO push_subscriptions
          (user_id, endpoint, p256dh_key, auth_key, created_at, updated_at)
        VALUES
          (1, 'https://push.example/legacy', 'legacy-key', 'legacy-auth', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      assert_equal 2, connection.select_value("SELECT COUNT(*) FROM push_subscriptions").to_i
    end
  end

  test "refuses destructive rollback after identity data exists" do
    with_temporary_database do |connection, context|
      context.up(MIGRATION_VERSION)
      insert_current_user_and_identity(connection)

      error = assert_raises(StandardError) do
        context.down(PREVIOUS_SCHEMA_VERSION)
      end

      assert_kind_of ActiveRecord::IrreversibleMigration, error.cause
      assert connection.data_source_exists?("identities")
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM identities").to_i
    end
  end

  test "refuses destructive rollback after a non-legacy session exists" do
    with_temporary_database do |connection, context|
      context.up(MIGRATION_VERSION)
      insert_current_user(connection)
      connection.execute <<~SQL
        INSERT INTO sessions
          (user_id, token, last_active_at, authentication_method, created_at, updated_at)
        VALUES
          (1, 'password-session', CURRENT_TIMESTAMP, 'password', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL

      error = assert_raises(StandardError) do
        context.down(PREVIOUS_SCHEMA_VERSION)
      end

      assert_kind_of ActiveRecord::IrreversibleMigration, error.cause
      assert connection.column_exists?(:sessions, :authentication_method)
    end
  end

  test "refuses rollback while durable work is pending" do
    with_temporary_database do |connection, context|
      context.up(MIGRATION_VERSION)
      insert_current_user(connection)
      insert_current_message(connection)
      connection.execute <<~SQL
        INSERT INTO message_effects
          (message_id, room_id, message_client_id, effect, deduplication_key, attempts, created_at, updated_at)
        VALUES
          (1, 1, 'current-message', 'broadcast_create', 'broadcast_create', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL

      error = assert_raises(StandardError) do
        context.down(PREVIOUS_SCHEMA_VERSION)
      end

      assert_kind_of ActiveRecord::IrreversibleMigration, error.cause
      assert connection.data_source_exists?("message_effects")
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM message_effects").to_i
    end
  end

  test "migration and checked-in schema have the same reliable-work contract" do
    migrated_contract = nil
    migrated_message_checks = nil
    migrated_message_index = nil
    migrated_push_index = nil
    with_temporary_database do |connection, context|
      context.up
      migrated_contract = reliable_work_contract(connection)
      migrated_message_checks = message_client_id_check_contract(connection)
      migrated_message_index = message_client_id_index_contract(connection)
      migrated_push_index = push_session_index_contract(connection)
    end

    with_temporary_database do |connection, _context|
      load Rails.root.join("db/schema.rb")
      assert_equal migrated_contract, reliable_work_contract(connection)
      assert_equal migrated_message_checks, message_client_id_check_contract(connection)
      assert_equal migrated_message_index, message_client_id_index_contract(connection)
      assert_equal migrated_push_index, push_session_index_contract(connection)
    end
  end

  test "ban cleanup terminal states are mutually exclusive in the database" do
    with_temporary_database do |connection, context|
      context.up
      insert_current_user(connection)

      %w[ completed_at failed_at ].each_with_index do |other_terminal, index|
        assert_raises(ActiveRecord::StatementInvalid) do
          connection.execute <<~SQL
            INSERT INTO ban_cleanup_intents
              (user_id, generation, canceled_at, #{other_terminal}, attempts, created_at, updated_at)
            VALUES
              (1, #{index + 1}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          SQL
        end
      end
    end
  end

  private
    def with_temporary_database
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-oidc-migration") do |directory|
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(directory, "migration.sqlite3"))
        yield ActiveRecord::Base.connection, ActiveRecord::Base.connection_pool.migration_context
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config)
    end

    def reliable_work_contract(connection)
      %w[ message_effects ban_cleanup_intents ban_cleanup_blob_entries ].index_with do |table|
        {
          columns: connection.columns(table).map { [ _1.name, _1.sql_type, _1.null, _1.default ] }.sort_by(&:first),
          indexes: connection.indexes(table).sort_by(&:name).map { [ _1.name, _1.columns, _1.unique, _1.where ] },
          checks: connection.check_constraints(table).sort_by(&:name).map { [ _1.name, _1.expression ] },
          foreign_keys: connection.foreign_keys(table).sort_by(&:name).map do
            [ _1.name, _1.to_table, _1.column, _1.primary_key, _1.on_delete ]
          end
        }
      end
    end

    def push_session_index_contract(connection)
      index = connection.indexes(:push_subscriptions).find { _1.columns == [ "session_id" ] }
      [ index.name, index.columns, index.unique, index.where ]
    end

    def message_client_id_check_contract(connection)
      %w[ messages message_effects ].to_h do |table|
        checks = connection.check_constraints(table).filter_map do |constraint|
          [ constraint.name, constraint.expression ] if constraint.name.include?("client_message_id_bytes")
        end
        [ table, checks.sort ]
      end
    end

    def message_client_id_index_contract(connection)
      index = connection.indexes(:messages).find { _1.name == CreateIdentities::MESSAGE_CLIENT_ID_INDEX_NAME }
      [ index.name, index.columns, index.unique, index.where ]
    end

    def normalized_email_contract(connection)
      column = connection.columns(:users).find { _1.name == "normalized_email_address" }
      index = connection.indexes(:users).find { _1.name == CreateIdentities::NORMALIZED_EMAIL_INDEX_NAME }
      {
        column: [ column.sql_type, column.null, column.default ],
        index: [ index.columns, index.unique, index.where ]
      }
    end

    def insert_legacy_user(connection, id:, email_address:)
      connection.execute <<~SQL
        INSERT INTO users
          (id, name, email_address, password_digest, role, status, created_at, updated_at)
        VALUES
          (#{connection.quote(id)}, 'Legacy User #{id}', #{connection.quote(email_address)},
           'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def insert_legacy_user_session_and_push(connection)
      connection.execute <<~SQL
        INSERT INTO users
          (id, name, email_address, password_digest, role, status, created_at, updated_at)
        VALUES
          (1, 'Legacy User', 'legacy@example.com', 'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO sessions
          (id, user_id, token, last_active_at, created_at, updated_at)
        VALUES
          (1, 1, 'legacy-token', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO push_subscriptions
          (user_id, endpoint, p256dh_key, auth_key, created_at, updated_at)
        VALUES
          (1, 'https://push.example/legacy', 'legacy-key', 'legacy-auth', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def insert_legacy_account(connection)
      connection.execute <<~SQL
        INSERT INTO accounts
          (id, name, join_code, singleton_guard, created_at, updated_at)
        VALUES
          (1, 'Legacy Campfire', 'legacy-join-code', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def insert_legacy_banned_user_and_message(connection)
      connection.execute <<~SQL
        INSERT INTO users
          (id, name, email_address, password_digest, role, status, created_at, updated_at)
        VALUES
          (1, 'Banned User', 'banned@example.com', 'digest', 0, 2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 'Active User', 'active@example.com', 'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO rooms
          (id, name, type, creator_id, created_at, updated_at)
        VALUES
          (1, 'Legacy Room', 'Rooms::Closed', 2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO memberships
          (room_id, user_id, involvement, created_at, updated_at)
        VALUES
          (1, 1, 'mentions', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (1, 2, 'mentions', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO messages
          (id, room_id, creator_id, client_message_id, created_at, updated_at)
        VALUES
          (1, 1, 1, 'legacy-banned-message', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def insert_legacy_duplicate_messages(connection)
      connection.execute <<~SQL
        INSERT INTO users
          (id, name, email_address, password_digest, role, status, created_at, updated_at)
        VALUES
          (2, 'Second Legacy User', 'second-legacy@example.com', 'digest', 0, 0,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO rooms
          (id, name, type, creator_id, created_at, updated_at)
        VALUES
          (1, 'Legacy Room', 'Room::Open', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO messages
          (id, room_id, creator_id, client_message_id, created_at, updated_at)
        VALUES
          (1, 1, 1, 'duplicate-message', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 1, 2, 'duplicate-message', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (3, 1, 2, '__campfire_legacy_duplicate_2', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO boosts
          (id, message_id, booster_id, content, created_at, updated_at)
        VALUES
          (1, 2, 1, '+1', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def insert_legacy_message(connection, client_message_id:)
      connection.execute <<~SQL
        INSERT INTO rooms
          (id, name, type, creator_id, created_at, updated_at)
        VALUES
          (1, 'Legacy Room', 'Room::Open', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO messages
          (id, room_id, creator_id, client_message_id, created_at, updated_at)
        VALUES
          (1, 1, 1, #{connection.quote(client_message_id)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    def insert_current_user_and_identity(connection)
      insert_current_user(connection)
      if connection.column_exists?(:identities, :scim_id)
        connection.execute <<~SQL
          INSERT INTO identities
            (user_id, issuer, subject, provider_fingerprint, scim_id, provisioned, created_at, updated_at)
          VALUES
            (1, 'https://idp.example.com', 'subject', 'fingerprint',
             '00000000-0000-4000-8000-000000000001', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      else
        connection.execute <<~SQL
          INSERT INTO identities
            (user_id, issuer, subject, provider_fingerprint, provisioned, created_at, updated_at)
          VALUES
            (1, 'https://idp.example.com', 'subject', 'fingerprint', 0,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end

    def insert_current_user(connection)
      connection.execute <<~SQL
        INSERT INTO users
          (id, name, email_address, password_digest, role, status, created_at, updated_at)
        VALUES
          (1, 'OIDC User', 'oidc@example.com', 'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end


    def insert_current_message(connection)
      connection.execute <<~SQL
        INSERT INTO rooms
          (id, name, type, creator_id, created_at, updated_at)
        VALUES
          (1, 'Current Room', 'Rooms::Open', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO messages
          (id, room_id, creator_id, client_message_id, created_at, updated_at)
        VALUES
          (1, 1, 1, 'current-message', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
end
