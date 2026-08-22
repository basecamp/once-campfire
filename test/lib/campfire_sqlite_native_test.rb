require "test_helper"
require "tmpdir"

class CampfireSQLiteNativeTest < ActiveSupport::TestCase
  test "reports the descriptor owned by each exact SQLite connection" do
    Dir.mktmpdir("campfire-sqlite-native") do |directory|
      path = Pathname(directory).join("database.sqlite3")
      first = SQLite3::Database.new(path.to_s)
      second = SQLite3::Database.new(path.to_s)
      decoy = File.open(path, "rb")

      first_descriptor = CampfireSQLiteNative.main_database_descriptor(first)
      second_descriptor = CampfireSQLiteNative.main_database_descriptor(second)
      expected = path.lstat

      assert_not_equal first_descriptor, second_descriptor
      assert_not_equal decoy.fileno, first_descriptor
      assert_not_equal decoy.fileno, second_descriptor
      [ first_descriptor, second_descriptor ].each do |descriptor|
        actual = IO.for_fd(descriptor, autoclose: false).stat
        assert_equal [ expected.dev, expected.ino, expected.ftype ],
          [ actual.dev, actual.ino, actual.ftype ]
      end
    ensure
      first&.close
      second&.close
      decoy&.close
    end
  end

  test "connection-specific moved-file detection survives a same-path replacement" do
    Dir.mktmpdir("campfire-sqlite-native-move") do |directory|
      root = Pathname(directory)
      path = root.join("database.sqlite3")
      moved = root.join("moved.sqlite3")
      database = SQLite3::Database.new(path.to_s)
      database.execute("CREATE TABLE records (id integer)")

      assert_not CampfireSQLiteNative.main_database_moved?(database)
      File.rename path, moved
      replacement = SQLite3::Database.new(path.to_s)
      replacement.close

      assert CampfireSQLiteNative.main_database_moved?(database)
    ensure
      database&.close
    end
  end
end
