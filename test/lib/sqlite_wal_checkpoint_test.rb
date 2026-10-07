require "test_helper"

class SqliteWalCheckpointTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir("sqlite-wal-checkpoint")
    SqliteWalCheckpoint.reset!
    SqliteWalCheckpoint.lock_path = File.join(@tmpdir, "checkpoint.lock")
  end

  teardown do
    SqliteWalCheckpoint.reset!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  test "connections disable WAL auto-checkpoint so commits do not fsync on the writer" do
    assert_equal 0, ActiveRecord::Base.connection.select_value("PRAGMA wal_autocheckpoint").to_i
  end

  test "a passive checkpoint against the primary database does not raise" do
    assert_nothing_raised { SqliteWalCheckpoint.checkpoint }
  end

  test "does not start a background thread in test by default" do
    assert_nil SqliteWalCheckpoint.start
    assert_empty checkpoint_threads
  end

  test "start with enabled: true runs a named contender thread that stop joins" do
    thread = SqliteWalCheckpoint.start(interval: 0.05, enabled: true)
    assert thread.alive?
    wait_until { thread.name == "sqlite-wal-checkpoint" }

    SqliteWalCheckpoint.stop
    assert_not thread.alive?
    assert_empty checkpoint_threads
  end

  test "tick checkpoints through the elected lock holder" do
    db_path = build_wal_database(rows: 50)
    SqliteWalCheckpoint.database_path_override = db_path

    assert_equal :checkpointed, SqliteWalCheckpoint.tick
  end

  test "tick reports busy while another process holds the lock and succeeds after it exits" do
    db_path = build_wal_database(rows: 20)
    SqliteWalCheckpoint.database_path_override = db_path
    lock = SqliteWalCheckpoint.lock_path
    ready = File.join(@tmpdir, "holder-ready")

    holder = spawn_lock_holder(lock, ready_path: ready, hold_for: 0.4)

    begin
      wait_until { File.exist?(ready) }
      assert_equal :busy, SqliteWalCheckpoint.tick
    ensure
      Process.wait(holder)
    end

    assert_equal :checkpointed, SqliteWalCheckpoint.tick
  end

  test "passive checkpoint moves WAL pages after writes with autocheckpoint disabled" do
    db_path = File.join(@tmpdir, "writer-#{SecureRandom.hex(4)}.sqlite3")

    SQLite3::Database.new(db_path) do |writer|
      writer.execute("PRAGMA journal_mode=WAL")
      writer.execute("PRAGMA wal_autocheckpoint=0")
      writer.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, body TEXT)")
      200.times do |i|
        writer.execute("INSERT INTO items (body) VALUES (?)", "row-#{i}-#{"x" * 200}")
      end

      wal_path = "#{db_path}-wal"
      assert File.exist?(wal_path), "expected a WAL file after inserts"
      assert File.size(wal_path) > 0

      SqliteWalCheckpoint.database_path_override = db_path
      assert SqliteWalCheckpoint.send(:acquire_lock)
      begin
        _busy, _log, checkpointed = SqliteWalCheckpoint.checkpoint
        assert checkpointed.to_i > 0, "expected PASSIVE checkpoint to copy WAL pages, got #{checkpointed.inspect}"
      ensure
        SqliteWalCheckpoint.send(:release_lock)
      end
    end
  end

  test "a contender thread takes over checkpointing after the lock holder stops" do
    db_path = build_wal_database(rows: 30)
    SqliteWalCheckpoint.database_path_override = db_path
    lock = SqliteWalCheckpoint.lock_path
    ready = File.join(@tmpdir, "holder-ready")

    holder = spawn_lock_holder(lock, ready_path: ready, hold_for: 0.25)
    wait_until { File.exist?(ready) }

    contender = SqliteWalCheckpoint.start(interval: 0.05, enabled: true)

    begin
      assert_equal :busy, SqliteWalCheckpoint.tick
      Process.wait(holder)
      holder = nil

      wait_until(timeout: 2) { lock_held_by_other_process?(lock) }
    ensure
      Process.wait(holder) if holder
      SqliteWalCheckpoint.stop
      assert_not contender.alive?
    end
  end

  private
    def checkpoint_threads
      Thread.list.select { |thread| thread.name == "sqlite-wal-checkpoint" }
    end

    def build_wal_database(rows:)
      path = File.join(@tmpdir, "writer-#{SecureRandom.hex(4)}.sqlite3")

      SQLite3::Database.new(path) do |database|
        database.execute("PRAGMA journal_mode=WAL")
        database.execute("PRAGMA wal_autocheckpoint=0")
        database.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, body TEXT)")
        rows.times do |i|
          database.execute("INSERT INTO items (body) VALUES (?)", "row-#{i}-#{"x" * 200}")
        end
      end

      path
    end

    def spawn_lock_holder(lock, ready_path:, hold_for:)
      Process.spawn(
        RbConfig.ruby, "-e", <<~RUBY
          require "fileutils"
          lock = #{lock.inspect}
          ready = #{ready_path.inspect}
          FileUtils.mkdir_p(File.dirname(lock))
          file = File.open(lock, File::RDWR | File::CREAT, 0644)
          abort "lock failed" unless file.flock(File::LOCK_EX | File::LOCK_NB)
          File.write(ready, "1")
          sleep #{hold_for}
        RUBY
      )
    end

    def lock_held_by_other_process?(lock)
      return false unless File.exist?(lock)

      probe = File.open(lock, File::RDWR | File::CREAT, 0644)
      if probe.flock(File::LOCK_EX | File::LOCK_NB)
        probe.flock(File::LOCK_UN)
        probe.close
        false
      else
        probe.close
        true
      end
    end

    def wait_until(timeout: 1)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
    end
end
