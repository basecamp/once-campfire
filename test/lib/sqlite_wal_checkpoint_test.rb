require "test_helper"

class SqliteWalCheckpointTest < ActiveSupport::TestCase
  test "connections disable WAL auto-checkpoint so commits do not fsync on the writer" do
    assert_equal 0, ActiveRecord::Base.connection.raw_connection.wal_autocheckpoint
  end

  test "a passive checkpoint against the primary database does not raise" do
    assert_nothing_raised { SqliteWalCheckpoint.checkpoint }
  end

  test "does not start a background thread in test" do
    assert_nil SqliteWalCheckpoint.start
    assert_empty Thread.list.select { |thread| thread.name == "sqlite-wal-checkpoint" }
  end
end
