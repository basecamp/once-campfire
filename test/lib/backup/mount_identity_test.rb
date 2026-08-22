require "test_helper"
require "tmpdir"

require Rails.root.join("lib/campfire_backup/mount_identity")

class MountIdentityTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "distinguishes independent mounts on one filesystem from aliases of one source" do
    entries = CampfireBackup::MountIdentity.parse(<<~MOUNTINFO)
      101 1 8:1 /docker/volumes/campfire/_data /rails/storage rw,relatime - ext4 /dev/sda1 rw
      102 1 8:1 /docker/volumes/campfire/_data /recovery/alias rw,relatime - ext4 /dev/sda1 rw
      103 1 8:1 /docker/volumes/recovery/_data /recovery/independent rw,relatime - ext4 /dev/sda1 rw
    MOUNTINFO

    storage, aliased, independent = entries
    nested_alias = CampfireBackup::MountIdentity::Entry.new(
      mount_id: 104, parent_id: 1, device: "8:1",
      root: "/docker/volumes/campfire/_data/recovery", mount_point: "/nested-alias",
      filesystem_type: "ext4", source: "/dev/disk/by-label/data"
    )

    assert_equal storage.source_identity, aliased.source_identity
    assert_not_equal storage.source_identity, independent.source_identity
    assert_equal storage.device, independent.device
    assert storage.same_source_volume?(aliased)
    assert storage.same_source_volume?(nested_alias)
    assert_not storage.same_source_volume?(independent)
  end

  test "selects the deepest decoded mount point and fails closed on malformed data" do
    Dir.mktmpdir("campfire-mount-identity") do |directory|
      root = Pathname(directory)
      mounted = root.join("mounted volume").tap(&:mkpath)
      child = mounted.join("recovery").tap(&:mkpath)
      mountinfo = root.join("mountinfo")
      canonical_root = root.realpath
      canonical_mount = mounted.realpath
      escaped_mount = canonical_mount.to_s.gsub(" ") { "\\040" }
      mountinfo.write <<~MOUNTINFO
        100 1 8:1 / #{canonical_root} rw,relatime - ext4 /dev/sda1 rw
        101 100 8:1 /docker/volumes/recovery/_data #{escaped_mount} rw,relatime - ext4 /dev/sda1 rw
      MOUNTINFO

      identity = CampfireBackup::MountIdentity.for_path(child, mountinfo_path: mountinfo)

      assert_equal 101, identity.mount_id
      assert_equal canonical_mount.to_s, identity.mount_point
      assert_raises(CampfireBackup::MountIdentity::Error) do
        CampfireBackup::MountIdentity.parse("not mountinfo\n")
      end
    end
  end
end
