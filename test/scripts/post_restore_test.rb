require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class PostRestoreTest < ActiveSupport::TestCase
  setup do
    @app_root = Dir.mktmpdir("campfire-post-restore")
  end

  teardown do
    FileUtils.remove_entry(@app_root)
  end

  test "refuses legacy backups before replacing the primary database when the queue database exists" do
    write_file("storage/backups/production.sqlite3", "restored primary")
    write_file("storage/db/production.sqlite3", "current primary")
    write_file("storage/db/production_queue.sqlite3", "current queue")

    output, status = run_hook

    assert_not status.success?
    assert_match "Queue database snapshot missing", output
    assert_equal "current primary", read_file("storage/db/production.sqlite3")
    assert_equal "current queue", read_file("storage/db/production_queue.sqlite3")
  end

  test "restores primary and queue databases and removes stale SQLite sidecars" do
    write_file("storage/backups/production.sqlite3", "restored primary")
    write_file("storage/backups/production_queue.sqlite3", "restored queue")
    write_file("storage/db/production.sqlite3", "current primary")
    write_file("storage/db/production.sqlite3-wal", "stale primary wal")
    write_file("storage/db/production.sqlite3-shm", "stale primary shm")
    write_file("storage/db/production_queue.sqlite3", "current queue")
    write_file("storage/db/production_queue.sqlite3-wal", "stale queue wal")
    write_file("storage/db/production_queue.sqlite3-shm", "stale queue shm")

    _output, status = run_hook

    assert status.success?
    assert_equal "restored primary", read_file("storage/db/production.sqlite3")
    assert_equal "restored queue", read_file("storage/db/production_queue.sqlite3")
    refute File.exist?(path("storage/db/production.sqlite3-wal"))
    refute File.exist?(path("storage/db/production.sqlite3-shm"))
    refute File.exist?(path("storage/db/production_queue.sqlite3-wal"))
    refute File.exist?(path("storage/db/production_queue.sqlite3-shm"))
  end

  test "restores a legacy primary snapshot when no queue database exists" do
    write_file("storage/backups/production.sqlite3", "restored primary")

    _output, status = run_hook

    assert status.success?
    assert_equal "restored primary", read_file("storage/db/production.sqlite3")
    refute File.exist?(path("storage/db/production_queue.sqlite3"))
  end

  private
    def run_hook
      Open3.capture2e(
        { "APP_ROOT" => @app_root, "RAILS_ENV" => "production" },
        "bash",
        Rails.root.join("hooks/post-restore").to_s
      )
    end

    def write_file(relative_path, contents)
      file_path = path(relative_path)
      FileUtils.mkdir_p(File.dirname(file_path))
      File.write(file_path, contents)
    end

    def read_file(relative_path)
      File.read(path(relative_path))
    end

    def path(relative_path)
      File.join(@app_root, relative_path)
    end
end
