require "test_helper"
require "tmpdir"

class CampfireBackup::RecoveryMarkersTest < ActiveSupport::TestCase
  test "publishes verifies and invalidates clean shutdown proof" do
    with_storage do |storage|
      boot_id = CampfireBackup::RecoveryMarkers.new_boot_id

      assert CampfireBackup::RecoveryMarkers.publish_clean_shutdown!(storage, boot_id:)
      proof = CampfireBackup::RecoveryMarkers.verify_clean_shutdown!(storage)

      assert_equal boot_id, proof.fetch("boot_id")
      assert CampfireBackup::RecoveryMarkers.invalidate_clean_shutdown!(storage)
      error = assert_raises(RuntimeError) do
        CampfireBackup::RecoveryMarkers.verify_clean_shutdown!(storage)
      end
      assert_match "proof is missing", error.message
    end
  end

  test "rejects malformed and linked clean shutdown proof" do
    with_storage do |storage|
      marker = storage.join(CampfireBackup::RecoveryMarkers::CLEAN_SHUTDOWN_FILENAME)
      marker.write "not json"

      error = assert_raises(RuntimeError) do
        CampfireBackup::RecoveryMarkers.verify_clean_shutdown!(storage)
      end
      assert_match "proof is invalid", error.message

      marker.unlink
      outside = storage.dirname.join("outside-proof").tap { _1.write "preserve" }
      File.link outside, marker
      error = assert_raises(RuntimeError) do
        CampfireBackup::RecoveryMarkers.verify_clean_shutdown!(storage)
      end
      assert_match "independent regular file", error.message
      assert_equal "preserve", outside.read
    end
  end

  test "does not leave valid clean proof when publication durability fails" do
    with_storage do |storage|
      redis = storage.join("redis")
      CampfireBackup::RecoveryMarkers.stubs(:flush_directory).with(redis).returns(nil)
      CampfireBackup::RecoveryMarkers.stubs(:flush_directory).with(storage).raises(Errno::ENOTSUP)

      assert_raises(Errno::ENOTSUP) do
        CampfireBackup::RecoveryMarkers.publish_clean_shutdown!(
          storage, boot_id: CampfireBackup::RecoveryMarkers.new_boot_id
        )
      end

      assert_not storage.join(CampfireBackup::RecoveryMarkers::CLEAN_SHUTDOWN_FILENAME).exist?
    end
  end

  test "does not publish clean proof when Redis persistence cannot be flushed" do
    with_storage do |storage|
      redis_file = storage.join("redis", "appendonly.aof").tap { _1.write "queued work" }
      CampfireBackup::RecoveryMarkers.stubs(:flush_regular_file).with(redis_file).raises(Errno::EIO)

      assert_raises(Errno::EIO) do
        CampfireBackup::RecoveryMarkers.publish_clean_shutdown!(
          storage, boot_id: CampfireBackup::RecoveryMarkers.new_boot_id
        )
      end

      assert_not storage.join(CampfireBackup::RecoveryMarkers::CLEAN_SHUTDOWN_FILENAME).exist?
    end
  end

  test "restore evidence is durable and blocks use until explicitly completed" do
    with_storage do |storage|
      marker = CampfireBackup::RecoveryMarkers.begin_restore!(
        storage, backup_id: "20260731T120000Z-0123456789abcdef", operation_id: "1" * 32
      )

      error = assert_raises(RuntimeError) do
        CampfireBackup::RecoveryMarkers.assert_restore_complete!(storage)
      end
      assert_match "Discard and recreate", error.message

      assert CampfireBackup::RecoveryMarkers.complete_restore!(marker)
      assert CampfireBackup::RecoveryMarkers.assert_restore_complete!(storage)
    end
  end

  test "preserves restore evidence when marker durability fails" do
    with_storage do |storage|
      CampfireBackup::RecoveryMarkers.stubs(:flush_directory).with(storage).raises(Errno::ENOTSUP)

      assert_raises(Errno::ENOTSUP) do
        CampfireBackup::RecoveryMarkers.begin_restore!(
          storage, backup_id: "20260731T120000Z-0123456789abcdef", operation_id: "1" * 32
        )
      end

      assert storage.join(CampfireBackup::RecoveryMarkers::RESTORE_FILENAME).exist?
      assert_raises(RuntimeError) do
        CampfireBackup::RecoveryMarkers.assert_restore_complete!(storage)
      end
    end
  end

  private
    def with_storage
      Dir.mktmpdir("campfire-recovery-markers") do |directory|
        storage = Pathname(directory).join("storage").tap(&:mkpath)
        storage.join("redis").mkpath
        yield storage
      end
    end
end
