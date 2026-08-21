require "test_helper"
require "tmpdir"

load Rails.root.join("script/admin/extract-backup") unless defined?(BackupExtractor)
load Rails.root.join("script/admin/install-backup") unless defined?(BackupInstaller)

class RestoreRetryTest < ActiveSupport::TestCase
  BACKUP_ID = "20260731T120000Z-0123456789abcdef"
  ENCRYPTION_KEY = "restore retry encryption key".ljust(32, "!")
  class SimulatedCrash < Exception; end

  test "extract refuses a dirty destination with an exact disposable cleanup instruction" do
    Dir.mktmpdir("campfire-extract-retry") do |directory|
      root = Pathname(directory)
      archive = root.join("archive.tar.gz").tap { _1.write "archive" }
      destination = root.join("restore").tap(&:mkpath)
      unrelated = destination.join("keep.txt").tap { _1.write "keep" }
      CampfireBackup::Authentication.stubs(:verify_archive!).returns(true)

      error = assert_raises(RuntimeError) do
        BackupExtractor.extract(
          archive_path: archive, destination_directory: destination, backup_id: BACKUP_ID,
          expected_installation_fingerprint: "f" * 64, expected_environment: "test",
          authentication_key: "k" * 32,
          encryption_keyring: CampfireBackup::BackupEncryption::Keyring.new(
            active_id: "restore-retry-test", active_key: ENCRYPTION_KEY
          )
        )
      end

      assert_match "Remove and recreate this disposable destination", error.message
      assert_equal "keep", unrelated.read
    end
  end

  test "install refuses a dirty destination without deleting it" do
    Dir.mktmpdir("campfire-install-retry") do |directory|
      root = Pathname(directory)
      generation = root.join(BACKUP_ID).tap(&:mkpath)
      destination = root.join("storage").tap(&:mkpath)
      unrelated = destination.join("keep.txt").tap { _1.write "keep" }

      error = assert_raises(RuntimeError) do
        BackupInstaller.install(
          generation_path: generation, storage_directory: destination,
          expected_installation_fingerprint: "f" * 64, expected_environment: "test",
          authentication_key: "k" * 32,
          runtime_uid: Process.euid, runtime_gid: Process.egid
        )
      end

      assert_match "Remove and recreate this disposable destination", error.message
      assert_equal "keep", unrelated.read
    end
  end

  test "install rejects ownership that does not match the image runtime" do
    Dir.mktmpdir("campfire-install-ownership") do |directory|
      root = Pathname(directory)
      generation = root.join(BACKUP_ID).tap(&:mkpath)
      destination = root.join("storage").tap(&:mkpath)

      error = assert_raises(RuntimeError) do
        BackupInstaller.install(
          generation_path: generation, storage_directory: destination,
          expected_installation_fingerprint: "f" * 64, expected_environment: "test",
          authentication_key: "k" * 32,
          owner_uid: 1001, owner_gid: 1001, runtime_uid: 1000, runtime_gid: 1000
        )
      end

      assert_match "must match Campfire image UID 1000 and GID 1000", error.message
      assert_empty destination.children.reject {
        _1.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
      }
    end
  end

  test "the reserved root lock is excluded while nested lock-looking files remain content" do
    Dir.mktmpdir("campfire-install-membership") do |directory|
      storage = Pathname(directory)
      legacy_lock_name = ".campfire-operation.lock"
      storage.join(legacy_lock_name).write "root lock"
      nested = storage.join("files", legacy_lock_name)
      nested.dirname.mkpath
      nested.write "unexpected"
      nested_marker = storage.join(
        "files", CampfireBackup::RecoveryMarkers::RESTORE_FILENAME
      ).tap { _1.write "content" }

      assert_equal [ "files/#{legacy_lock_name}", "files/#{nested_marker.basename}" ],
        BackupInstaller.send(:storage_files, storage)
    end
  end

  test "final metadata validation is bound to the inventoried inode" do
    Dir.mktmpdir("campfire-install-inventory-inode") do |directory|
      storage = Pathname(directory)
      path = storage.join("proof.txt").tap { _1.write "authenticated" }
      inventory = BackupInstaller.send(:storage_inventory, storage)
      original = storage.join("original-proof.txt")
      File.rename path, original
      path.write "authenticated"
      metadata = {
        "bytes" => path.size,
        "sha256" => Digest::SHA256.file(path).hexdigest
      }

      error = assert_raises(RuntimeError) do
        BackupInstaller.send(
          :verify_metadata!, path, metadata,
          expected_identity: inventory.fetch("proof.txt").fetch(:identity)
        )
      end

      assert_match "changed during final validation", error.message
      assert_equal "authenticated", original.read
    end
  end

  test "every precommit restore interruption poisons the disposable destination" do
    manifest = {
      "backup_id" => BACKUP_ID,
      "files" => [],
      "database" => { "path" => "test.sqlite3" }
    }
    BackupVerifier.stubs(:verify).returns(true)
    CampfireBackup::Authentication.stubs(:verify_manifest!).returns(manifest)
    BackupInstaller.stubs(:install_files)
    BackupInstaller.stubs(:apply_runtime_ownership!)
    BackupInstaller.stubs(:flush_directory_tree)
    BackupInstaller.stubs(:verify_installed!)
    BackupInstaller.stubs(:verify_runtime_access!)
    BackupInstaller.stubs(:assert_storage_inventory_current!)

    %w[ marked claimed installed owned synced verified ].each do |boundary|
      Dir.mktmpdir("campfire-install-interruption") do |directory|
        root = Pathname(directory)
        generation = root.join(BACKUP_ID).tap(&:mkpath)
        generation.join("manifest.json").write "{}"
        destination = root.join("storage")

        assert_raises(SimulatedCrash, boundary) do
          BackupInstaller.install(
            generation_path: generation, storage_directory: destination,
            expected_installation_fingerprint: "f" * 64, expected_environment: "test",
            authentication_key: "k" * 32,
            runtime_uid: Process.euid, runtime_gid: Process.egid,
            fault_after: ->(step) { raise SimulatedCrash if step == boundary }
          )
        end

        assert destination.join(CampfireBackup::RecoveryMarkers::RESTORE_FILENAME).file?, boundary
        error = assert_raises(RuntimeError) do
          BackupInstaller.install(
            generation_path: generation, storage_directory: destination,
            expected_installation_fingerprint: "f" * 64, expected_environment: "test",
            authentication_key: "k" * 32,
            runtime_uid: Process.euid, runtime_gid: Process.egid
          )
        end
        assert_match "Discard and recreate", error.message
      end
    end
  end

  test "interruption after the restore commit retains verified bytes without a marker" do
    manifest = {
      "backup_id" => BACKUP_ID,
      "files" => [],
      "database" => { "path" => "test.sqlite3" }
    }
    BackupVerifier.stubs(:verify).returns(true)
    CampfireBackup::Authentication.stubs(:verify_manifest!).returns(manifest)
    BackupInstaller.stubs(:install_files).with do |_generation, storage, _manifest, owned_paths, _lock|
      installed = storage.join("verified-bytes").tap { _1.write "complete" }
      owned_paths.record installed
      true
    end
    BackupInstaller.stubs(:apply_runtime_ownership!)
    BackupInstaller.stubs(:flush_directory_tree)
    BackupInstaller.stubs(:verify_installed!)
    BackupInstaller.stubs(:verify_runtime_access!)
    BackupInstaller.stubs(:assert_storage_inventory_current!)

    Dir.mktmpdir("campfire-install-commit") do |directory|
      root = Pathname(directory)
      generation = root.join(BACKUP_ID).tap(&:mkpath)
      generation.join("manifest.json").write "{}"
      destination = root.join("storage")

      assert_raises(SimulatedCrash) do
        BackupInstaller.install(
          generation_path: generation, storage_directory: destination,
          expected_installation_fingerprint: "f" * 64, expected_environment: "test",
          authentication_key: "k" * 32,
          runtime_uid: Process.euid, runtime_gid: Process.egid,
          fault_after: ->(step) { raise SimulatedCrash if step == "committed" }
        )
      end

      assert_equal "complete", destination.join("verified-bytes").read
      assert_not destination.join(CampfireBackup::RecoveryMarkers::RESTORE_FILENAME).exist?
    end
  end

  test "marker-removal and root-exposure failures relock the destination" do
    manifest = {
      "backup_id" => BACKUP_ID,
      "files" => [],
      "database" => { "path" => "test.sqlite3" }
    }
    BackupVerifier.stubs(:verify).returns(true)
    CampfireBackup::Authentication.stubs(:verify_manifest!).returns(manifest)
    BackupInstaller.stubs(:install_files)
    BackupInstaller.stubs(:apply_runtime_ownership!)
    BackupInstaller.stubs(:verify_installed!).returns({})
    BackupInstaller.stubs(:verify_runtime_access!)
    BackupInstaller.stubs(:assert_storage_inventory_current!).returns({})

    %w[ marker-removed root-exposed ].each do |boundary|
      Dir.mktmpdir("campfire-install-commit-window") do |directory|
        root = Pathname(directory)
        generation = root.join(BACKUP_ID).tap(&:mkpath)
        generation.join("manifest.json").write "{}"
        destination = root.join("storage")
        exposed = false

        begin
          assert_raises(SimulatedCrash, boundary) do
            BackupInstaller.install(
              generation_path: generation, storage_directory: destination,
              expected_installation_fingerprint: "f" * 64, expected_environment: "test",
              authentication_key: "k" * 32,
              runtime_uid: Process.euid, runtime_gid: Process.egid,
              fault_after: ->(step) {
                next unless step == boundary

                if boundary == "root-exposed"
                  exposed = (destination.stat.mode & 0o777) == 0o700
                end
                raise SimulatedCrash
              }
            )
          end

          assert_not destination.join(CampfireBackup::RecoveryMarkers::RESTORE_FILENAME).exist?, boundary
          assert_equal(boundary == "root-exposed", exposed, boundary)
          assert_equal 0o000, destination.stat.mode & 0o777, boundary
        ensure
          File.chmod 0o700, destination if destination.exist?
        end
      end
    end
  end

  test "production restore rejects a non-root installer before ownership handoff" do
    Process.stubs(:euid).returns(501)

    error = assert_raises(RuntimeError) do
      BackupInstaller.send(:runtime_ownership!, 1000, 1000, 1000, 1000, "production")
    end

    assert_match "must run as root", error.message
  end
end
