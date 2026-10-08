require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class SolidCacheRestoreTest < ActiveSupport::TestCase
  setup do
    @app_root = Dir.mktmpdir("campfire-solid-cache-restore")
  end

  teardown do
    FileUtils.remove_entry(@app_root)
  end

  test "restores the primary database and removes disposable cache and cable databases" do
    write_file("storage/backups/production.sqlite3", "restored primary")
    write_file("storage/db/production.sqlite3", "current primary")
    write_file("storage/db/production_cache.sqlite3", "stale cache")
    write_file("storage/db/production_cache.sqlite3-wal", "stale cache wal")
    write_file("storage/db/production_cache.sqlite3-shm", "stale cache shm")
    write_file("storage/db/production_cache.sqlite3-journal", "stale cache journal")
    write_file("storage/db/production_cable.sqlite3", "stale cable")
    write_file("storage/db/production_cable.sqlite3-wal", "stale cable wal")
    write_file("storage/db/production_cable.sqlite3-shm", "stale cable shm")
    write_file("storage/db/production_cable.sqlite3-journal", "stale cable journal")

    _output, status = run_hook

    assert status.success?
    assert_equal "restored primary", read_file("storage/db/production.sqlite3")
    refute File.exist?(path("storage/db/production_cache.sqlite3"))
    refute File.exist?(path("storage/db/production_cache.sqlite3-wal"))
    refute File.exist?(path("storage/db/production_cache.sqlite3-shm"))
    refute File.exist?(path("storage/db/production_cache.sqlite3-journal"))
    refute File.exist?(path("storage/db/production_cable.sqlite3"))
    refute File.exist?(path("storage/db/production_cable.sqlite3-wal"))
    refute File.exist?(path("storage/db/production_cable.sqlite3-shm"))
    refute File.exist?(path("storage/db/production_cable.sqlite3-journal"))
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
