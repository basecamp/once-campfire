require "test_helper"

class SqliteWalCheckpointTest < ActiveSupport::TestCase
  test "connections disable WAL auto-checkpoint so commits do not fsync on the writer" do
    assert_equal 0, ActiveRecord::Base.connection.raw_connection.wal_autocheckpoint
  end

  test "a passive checkpoint against the primary database does not raise" do
    assert_nothing_raised { SqliteWalCheckpoint.new.checkpoint }
  end

  test "the background loop is off in test" do
    assert_not Rails.application.config.x.sqlite_wal_checkpoint
  end
end
