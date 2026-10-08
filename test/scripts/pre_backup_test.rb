require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class PreBackupTest < ActiveSupport::TestCase
  setup do
    @app_root = Dir.mktmpdir("campfire-pre-backup")
  end

  teardown do
    FileUtils.remove_entry(@app_root)
  end

  test "requests ONCE's paused-volume fallback instead of taking live split snapshots" do
    output, status = Open3.capture2e(
      { "APP_ROOT" => @app_root },
      "bash",
      Rails.root.join("hooks/pre-backup").to_s
    )

    assert_not status.success?
    assert_match "asking ONCE to pause the container", output
    assert File.exist?(path("storage/backups/.once-paused-volume-backup"))
  end

  private
    def path(relative_path)
      File.join(@app_root, relative_path)
    end
end
