require "test_helper"
require "rake"
require "tmpdir"

Rails.application.load_tasks unless Rake::Task.task_defined?("room_messages_count:ensure")

class Room::MessagesCountTasksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @directory = Dir.mktmpdir("campfire-counter-tasks")
    @schema = File.join(@directory, "schema.rb")
    @migrations = File.join(@directory, "migrations")
    Dir.mkdir(@migrations)
    File.write(@schema, <<~RUBY)
      ActiveRecord::Schema[8.2].define(version: 0) do
        create_table :rooms, force: true do |t|
          t.integer :messages_count, default: 0, null: false
        end
        create_table :messages, force: true do |t|
          t.integer :room_id
          t.string :client_message_id
        end
      end
    RUBY
    @tasks = ActiveRecord::Tasks::DatabaseTasks
    @original_database_url = ENV.delete("DATABASE_URL")
    @original_environment = @tasks.env
    @original_configurations = ActiveRecord::Base.configurations
    @original_migrations = @tasks.migrations_paths
    @original_dump = ActiveRecord.dump_schema_after_migration
    @original_seed_loader = @tasks.seed_loader
    @tasks.migrations_paths = [ @migrations ]
    ActiveRecord.dump_schema_after_migration = false
  end

  teardown do
    ActiveRecord::Base.configurations = @original_configurations
    ENV["DATABASE_URL"] = @original_database_url if @original_database_url
    @tasks.env = @original_environment
    @tasks.migrations_paths = @original_migrations
    @tasks.seed_loader = @original_seed_loader
    ActiveRecord.dump_schema_after_migration = @original_dump
    FileUtils.remove_entry(@directory)
  end

  test "development schema task repairs both databases before restoring its original pool" do
    development = configuration("development")
    test = configuration("test")
    ActiveRecord::Base.configurations = { "development" => { "primary" => development.configuration_hash }, "test" => { "primary" => test.configuration_hash } }
    @tasks.env = "development"

    @tasks.with_temporary_connection(development) do |connection|
      @tasks.load_schema(development)
      original_path = connection.pool.db_config.database

      2.times do
        task = Rake::Task["db:schema:load"]
        task.all_prerequisite_tasks.each(&:reenable)
        task.reenable
        task.invoke

        assert_equal original_path, ActiveRecord::Base.connection_db_config.database
        assert Room::MessagesCount.triggers_installed?(connection)
        @tasks.with_temporary_connection(test) do |test_connection|
          assert Room::MessagesCount.triggers_installed?(test_connection)
          assert_counter_tracks_insert(test_connection)
        end
      end
    end
  end

  test "test schema task repairs the test database selected by purge" do
    config = configuration("test")
    ActiveRecord::Base.configurations = { "test" => { "primary" => config.configuration_hash } }

    @tasks.with_temporary_connection(config) do |connection|
      task = Rake::Task["db:test:load_schema"]
      task.all_prerequisite_tasks.each(&:reenable)
      task.reenable
      task.invoke
      assert Room::MessagesCount.triggers_installed?(connection)
      assert_counter_tracks_insert(connection)
    end
  end

  test "prepare installs schema triggers before loading seeds" do
    config = configuration("test")
    ActiveRecord::Base.configurations = { "test" => { "primary" => config.configuration_hash } }
    seeded = false
    loader = Object.new
    loader.define_singleton_method(:load_seed) do
      connection = ActiveRecord::Base.connection
      raise "seeds ran without counter triggers" unless Room::MessagesCount.triggers_installed?(connection)
      connection.execute("INSERT INTO rooms (id) VALUES (1)")
      connection.execute("INSERT INTO messages (room_id) VALUES (1), (1)")
      raise "seed counter is stale" unless connection.select_value("SELECT messages_count FROM rooms WHERE id = 1") == 2
      seeded = true
    end
    @tasks.seed_loader = loader

    @tasks.with_temporary_connection(config) do |connection|
      @tasks.prepare_all
      assert seeded
      assert Room::MessagesCount.triggers_installed?(connection)
      assert_equal 2, connection.select_value("SELECT messages_count FROM rooms WHERE id = 1")
    end
  end

  test "migrate repairs rebuilt message tables and repeats repair with no new migration" do
    config = configuration("test")
    File.write(File.join(@migrations, "20261008000100_change_counter_task_message_column.rb"), <<~RUBY)
      class ChangeCounterTaskMessageColumn < ActiveRecord::Migration[8.2]
        def change
          change_column :messages, :client_message_id, :text
        end
      end
    RUBY

    @tasks.with_temporary_connection(config) do |connection|
      @tasks.load_schema(config)
      Room::MessagesCount.ensure!(connection)
      assert_counter_tracks_insert(connection)
      @tasks.migrate
      assert Room::MessagesCount.triggers_installed?(connection)
      assert_counter_tracks_insert(connection)

      Room::MessagesCount.uninstall!(connection)
      connection.execute("INSERT INTO messages (room_id) VALUES (1)")
      assert_not_equal connection.select_value("SELECT COUNT(*) FROM messages WHERE room_id = 1"), connection.select_value("SELECT messages_count FROM rooms WHERE id = 1")
      @tasks.migrate
      assert Room::MessagesCount.triggers_installed?(connection)
      assert_equal connection.select_value("SELECT COUNT(*) FROM messages WHERE room_id = 1"), connection.select_value("SELECT messages_count FROM rooms WHERE id = 1")
    end
  end

  private
    def configuration(environment)
      ActiveRecord::DatabaseConfigurations::HashConfig.new(environment, "primary", {
        adapter: "sqlite3", database: File.join(@directory, "#{environment}.sqlite3"),
        default_transaction_mode: :immediate, schema_dump: @schema,
        migrations_paths: [ @migrations ]
      })
    end

    def assert_counter_tracks_insert(connection)
      connection.execute("INSERT INTO rooms (id) VALUES (1) ON CONFLICT DO NOTHING")
      before = connection.select_value("SELECT messages_count FROM rooms WHERE id = 1")
      connection.execute("INSERT INTO messages (room_id) VALUES (1)")
      assert_equal before + 1, connection.select_value("SELECT messages_count FROM rooms WHERE id = 1")
    end
end
