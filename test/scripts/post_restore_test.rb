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

  test "restores the primary database and removes the disposable queue database" do
    write_file("storage/backups/production.sqlite3", "restored primary")
    write_file("storage/db/production.sqlite3", "current primary")
    write_file("storage/db/production.sqlite3-wal", "stale primary wal")
    write_file("storage/db/production.sqlite3-shm", "stale primary shm")
    write_file("storage/db/production_queue.sqlite3", "current queue")
    write_file("storage/db/production_queue.sqlite3-wal", "stale queue wal")
    write_file("storage/db/production_queue.sqlite3-shm", "stale queue shm")
    write_file("storage/db/production_queue.sqlite3-journal", "stale queue journal")

    _output, status = run_hook

    assert status.success?
    assert_equal "restored primary", read_file("storage/db/production.sqlite3")
    refute File.exist?(path("storage/db/production.sqlite3-wal"))
    refute File.exist?(path("storage/db/production.sqlite3-shm"))
    %w[ production_queue.sqlite3 production_queue.sqlite3-wal production_queue.sqlite3-shm production_queue.sqlite3-journal ].each do |name|
      refute File.exist?(path("storage/db/#{name}")), name
    end
  end

  test "restores a backup taken before the queue database existed" do
    write_file("storage/backups/production.sqlite3", "restored primary")

    _output, status = run_hook

    assert status.success?
    assert_equal "restored primary", read_file("storage/db/production.sqlite3")
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
