require "test_helper"
require "tmpdir"
require "campfire_backup/schema_verifier"

class CampfireBackup::SchemaVerifierTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  CURRENT_SCHEMA_VERSION = 20260802010000

  test "accepts the schema loaded by db schema" do
    with_schema_database do |path|
      assert_nil CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
    end
  end

  test "production verification authorizes only its operation-owned temporary databases" do
    with_schema_database do |path|
      with_environment("RAILS_ENV" => "production") do
        assert_nil CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
      end
    end
  end

  test "rejects drift between migrations and db schema" do
    with_schema_database do |path|
      load_schema = CampfireBackup::SchemaVerifier.method(:load_schema!)
      CampfireBackup::SchemaVerifier.stubs(:load_schema!).with do |loaded_path|
        load_schema.call(loaded_path)
        database = SQLite3::Database.new(loaded_path.to_s)
        database.execute("CREATE TABLE schema_only (id INTEGER PRIMARY KEY)")
        database.close
        true
      end.returns(nil)

      error = assert_raises(RuntimeError) do
        CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
      end
      assert_match "migrations and db/schema.rb do not match", error.message
    end
  end

  test "ignores comments in stored SQL" do
    with_schema_database do |path|
      rewrite_schema(path, <<~SQL)
        UPDATE sqlite_schema
        SET sql = replace(sql, 'CHECK (operation', 'CHECK /* harmless comment */ (operation')
        WHERE type = 'table' AND name = 'oidc_flows'
      SQL

      assert_nil CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
    end
  end

  test "normalizes AUTOINCREMENT whitespace comments and case" do
    with_schema_database do |path|
      rewrite_schema(path, <<~SQL)
        UPDATE sqlite_schema
        SET sql = replace(
          sql,
          'PRIMARY KEY AUTOINCREMENT',
          'primary key /* identity allocation */  autoincrement'
        )
        WHERE type = 'table' AND name = 'accounts'
      SQL

      assert_nil CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
    end
  end

  test "rejects removed AUTOINCREMENT semantics" do
    with_schema_database do |path|
      rewrite_schema(path, <<~SQL)
        UPDATE sqlite_schema
        SET sql = replace(sql, 'PRIMARY KEY AUTOINCREMENT', 'PRIMARY KEY')
        WHERE type = 'table' AND name = 'accounts'
      SQL

      error = assert_raises(RuntimeError) do
        CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
      end
      assert_match "table accounts differs", error.message
    end
  end

  test "rejects added AUTOINCREMENT semantics" do
    with_schema_database do |path|
      rewrite_schema(path, <<~SQL)
        UPDATE sqlite_schema
        SET sql = replace(
          sql,
          'id INTEGER PRIMARY KEY, block BLOB',
          'id INTEGER PRIMARY KEY AUTOINCREMENT, block BLOB'
        )
        WHERE type = 'table' AND name = 'message_search_index_data'
      SQL

      error = assert_raises(RuntimeError) do
        CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
      end
      assert_match "table message_search_index_data differs", error.message
    end
  end

  test "rejects a changed column collation" do
    with_schema_database do |path|
      rewrite_schema(path, <<~SQL)
        UPDATE sqlite_schema
        SET sql = replace(sql, '"return_to" varchar', '"return_to" varchar COLLATE NOCASE')
        WHERE type = 'table' AND name = 'oidc_flows'
      SQL

      error = assert_raises(RuntimeError) do
        CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
      end
      assert_match "schema contract", error.message
    end
  end

  test "rejects an implicit unique autoindex" do
    with_schema_database do |path|
      add_inline_unique_constraint(path, table: "oidc_flows", column: "operation")

      error = assert_raises(RuntimeError) do
        CampfireBackup::SchemaVerifier.verify!(path, schema_version: CURRENT_SCHEMA_VERSION)
      end
      assert_match "unexpected index sqlite_autoindex_oidc_flows", error.message
    end
  end

  test "records SQLite table options" do
    Dir.mktmpdir("campfire-table-options") do |directory|
      path = Pathname(directory).join("options.sqlite3")
      database = SQLite3::Database.new(path.to_s)
      database.execute("CREATE TABLE keyed (key TEXT PRIMARY KEY) WITHOUT ROWID")
      database.execute("CREATE TABLE strict_events (id INTEGER PRIMARY KEY) STRICT")
      database.close

      signature = CampfireBackup::SchemaVerifier.send(:schema_signature, path)
      assert signature.dig(:tables, "keyed", :options, :without_rowid)
      assert signature.dig(:tables, "strict_events", :options, :strict)
    end
  end

  private
    def with_schema_database
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-loaded-schema") do |directory|
        path = Pathname(directory).join("loaded.sqlite3")
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3", database: path.to_s, default_transaction_mode: "immediate"
        )
        load Rails.root.join("db/schema.rb")
        ActiveRecord::Base.connection.disconnect!
        ActiveRecord::Base.establish_connection(original_config)
        yield path
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config) if original_config
    end

    def rewrite_schema(path, statement)
      database = SQLite3::Database.new(path.to_s)
      database.execute("PRAGMA writable_schema = ON")
      database.execute(statement)
      database.execute("PRAGMA writable_schema = OFF")
      database.close
    end

    def add_inline_unique_constraint(path, table:, column:)
      database = SQLite3::Database.new(path.to_s)
      create_sql = database.get_first_value(
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", table
      )
      replacement = %Q("#{column}" varchar NOT NULL UNIQUE)
      changed_sql = create_sql.sub(%Q("#{column}" varchar NOT NULL), replacement)
      raise "Test table definition changed" if changed_sql == create_sql

      indexes = database.execute(
        "SELECT sql FROM sqlite_schema WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL", table
      ).flatten
      columns = database.execute("PRAGMA table_info(#{quote_identifier(table)})").map { _1.fetch(1) }
      column_list = columns.map { quote_identifier(_1) }.join(", ")
      old_table = "__old_#{table}"

      database.transaction do
        database.execute("ALTER TABLE #{quote_identifier(table)} RENAME TO #{quote_identifier(old_table)}")
        database.execute(changed_sql)
        database.execute <<~SQL
          INSERT INTO #{quote_identifier(table)} (#{column_list})
          SELECT #{column_list} FROM #{quote_identifier(old_table)}
        SQL
        database.execute("DROP TABLE #{quote_identifier(old_table)}")
        indexes.each { database.execute(_1) }
      end
    ensure
      database&.close
    end

    def quote_identifier(value)
      %Q("#{value.to_s.gsub('"', '""')}")
    end

    def with_environment(values)
      previous = values.to_h { |key, _| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end
end
