require "test_helper"
require "tmpdir"
require Rails.root.join("db/migrate/20260802000000_create_credential_intents").to_s

class CreateCredentialIntentsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PREVIOUS_SCHEMA_VERSION = 20260730000000
  MIGRATION_VERSION = 20260802000000

  test "nonproduction rollback retains the reversible migration behavior" do
    with_temporary_database do |connection, context|
      context.up(MIGRATION_VERSION)

      context.down(PREVIOUS_SCHEMA_VERSION)

      assert_not connection.table_exists?(:credential_intents)
    end
  end

  test "direct production rollback authorizes before dropping credential intents" do
    with_temporary_database do |connection, context|
      context.up(MIGRATION_VERSION)

      error = with_environment("RAILS_ENV" => "production") do
        assert_raises(ActiveRecord::IrreversibleMigration) { CreateCredentialIntents.new.down }
      end

      assert_match "separately authenticated rollback archive", error.message
      assert connection.table_exists?(:credential_intents)
    end
  end

  private
    def with_temporary_database
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-credential-intent-migration") do |directory|
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3", database: File.join(directory, "migration.sqlite3")
        )
        yield ActiveRecord::Base.connection, ActiveRecord::Base.connection_pool.migration_context
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config)
    end

    def with_environment(values)
      previous = values.to_h { |key, _| [ key, ENV[key] ] }
      values.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      yield
    ensure
      previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end
end
