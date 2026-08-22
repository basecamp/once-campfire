require "test_helper"
require "tmpdir"

load Rails.root.join("script/admin/archive-backup") unless defined?(BackupArchiver)

class ArchivePublicationTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  BACKUP_ID = "20260731T120000Z-0123456789abcdef"
  AUTHENTICATION_KEY = "archive-publication-test-key".ljust(32, "!")
  ENCRYPTION_KEY = "archive-encryption-test-key".ljust(32, "!")
  ENCRYPTION_KEY_ID = "archive-test-2026-08"
  FINGERPRINT = "f" * 64

  class SimulatedCrash < Exception; end

  setup do
    BackupVerifier.stubs(:verify).returns(true)
  end

  test "publishes one self-contained encrypted artifact without plaintext metadata" do
    with_generation do |generation, destination|
      stdout = nil
      archive = nil
      stdout = capture_io do
        archive = BackupArchiver.archive(**archive_arguments(generation, destination))
      end.first
      report = JSON.parse(stdout)
      envelope = archive.binread

      assert_equal "campfire-#{BACKUP_ID}.campfire-backup", archive.basename.to_s
      assert_equal archive.to_s, report.fetch("archive")
      assert_equal ENCRYPTION_KEY_ID, report.fetch("encryption_key_id")
      assert_equal CampfireBackup::Authentication.key_id(AUTHENTICATION_KEY),
        report.fetch("authentication_key_id")
      assert_equal [ CampfireBackup::OperationLock::SHARED_FILENAME, archive.basename.to_s ].sort,
        destination.children.map { _1.basename.to_s }.sort
      assert_equal 0o640, archive.stat.mode & 0o777
      refute_includes envelope, "manifest.json"
      refute_includes envelope, "proof.txt"
      refute_includes envelope, FINGERPRINT
      refute_includes envelope, Digest::SHA256.hexdigest("database")

      metadata = CampfireBackup::BackupEncryption.envelope_metadata(archive)
      assert_equal ENCRYPTION_KEY_ID, metadata.fetch(:key_id)
    end
  end

  test "a completed encrypted publication is an idempotent retry" do
    with_generation do |generation, destination|
      first = nil
      capture_io { first = BackupArchiver.archive(**archive_arguments(generation, destination)) }
      bytes = first.binread
      nonce = CampfireBackup::BackupEncryption.envelope_metadata(first).fetch(:nonce)
      second = nil
      capture_io { second = BackupArchiver.archive(**archive_arguments(generation, destination)) }

      assert_equal first, second
      assert_equal bytes, second.binread
      assert_equal nonce,
        CampfireBackup::BackupEncryption.envelope_metadata(second).fetch(:nonce)
    end
  end

  test "retry completes an interrupted encrypted publication" do
    with_generation do |generation, destination|
      assert_raises(SimulatedCrash) do
        BackupArchiver.archive(
          **archive_arguments(generation, destination), fault_after: ->(step) {
            raise SimulatedCrash if step == "archive"
          }
        )
      end

      archive = archive_path(destination)
      staging = staging_path(destination)
      assert archive.file?
      assert staging.directory?
      assert File.identical?(archive, staging.join(archive.basename))

      capture_io { BackupArchiver.archive(**archive_arguments(generation, destination)) }

      assert archive.file?
      assert_equal 1, archive.stat.nlink
      assert_not staging.exist?
    end
  end

  test "a verified final archive is retryable after staging cleanup loses its marker" do
    with_generation do |generation, destination|
      assert_raises(SimulatedCrash) do
        BackupArchiver.archive(
          **archive_arguments(generation, destination), fault_after: ->(step) {
            raise SimulatedCrash if step == "archive"
          }
        )
      end
      archive = archive_path(destination)
      staging = staging_path(destination)
      original_bytes = archive.binread
      staging.join(BackupArchiver::STAGING_MARKER).delete

      _stdout, stderr = capture_io do
        retried = BackupArchiver.archive(**archive_arguments(generation, destination))
        assert_equal archive.realpath, retried.realpath
      end

      assert_equal original_bytes, archive.binread
      assert_not staging.exist?
      assert_empty stderr
    end
  end

  test "a conflicting final file raced into place is never overwritten" do
    with_generation do |generation, destination|
      archive = archive_path(destination)

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(
          **archive_arguments(generation, destination), fault_after: ->(step) {
            archive.write "raced bytes" if step == "staged"
          }
        )
      end

      assert_match "raced with a conflicting final file", error.message
      assert_equal "raced bytes", archive.read
      assert staging_path(destination).directory?
    end
  end

  test "a byte-identical independent final race is reconciled" do
    with_generation do |generation, destination|
      archive = archive_path(destination)
      staging = staging_path(destination)

      capture_io do
        BackupArchiver.archive(
          **archive_arguments(generation, destination), fault_after: ->(step) {
            FileUtils.copy_file staging.join(archive.basename), archive if step == "staged"
          }
        )
      end

      assert archive.file?
      assert_equal 1, archive.stat.nlink
      assert_not staging.exist?
    end
  end

  test "a hard-linked final race is rejected even when its bytes match" do
    with_generation do |generation, destination|
      archive = archive_path(destination)
      staging = staging_path(destination)
      outside = destination.dirname.join("outside-encrypted-backup")

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(
          **archive_arguments(generation, destination), fault_after: ->(step) {
            if step == "staged"
              FileUtils.copy_file staging.join(archive.basename), outside
              File.link outside, archive
            end
          }
        )
      end

      assert_match "raced with a conflicting final file", error.message
      assert_equal 2, outside.stat.nlink
      assert_equal outside.binread, archive.binread
      assert staging.directory?
    end
  end

  test "an unauthenticated staging directory is preserved" do
    with_generation do |generation, destination|
      staging = staging_path(destination).tap(&:mkpath)
      File.chmod 0o700, staging
      marker = staging.join(BackupArchiver::STAGING_MARKER).tap { _1.write "untrusted" }

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(**archive_arguments(generation, destination))
      end

      assert_match "ownership cannot be authenticated", error.message
      assert_equal "untrusted", marker.read
    end
  end

  test "a symbolic-link publication path is rejected without changing its target" do
    with_generation do |generation, destination|
      destination.mkpath
      target = destination.join("outside").tap { _1.write "preserve" }
      archive = archive_path(destination)
      File.symlink target, archive

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(**archive_arguments(generation, destination))
      end

      assert_match "independent regular file", error.message
      assert_equal "preserve", target.read
    end
  end

  test "archive publication contends on the destination-mounted shared lock" do
    with_generation do |generation, destination|
      destination.mkpath
      shared_path = destination.join(CampfireBackup::OperationLock::SHARED_FILENAME)
      File.open(shared_path, File::RDWR | File::CREAT, 0o600) do |shared_file|
        assert shared_file.flock(File::LOCK_EX | File::LOCK_NB)

        error = assert_raises(RuntimeError) do
          BackupArchiver.archive(**archive_arguments(generation, destination))
        end

        assert_match "in use by another process", error.message
      end
    end
  end

  test "staging exposes only ciphertext and a keyed ownership commitment" do
    with_generation do |generation, destination|
      staging = staging_path(destination)

      assert_raises(SimulatedCrash) do
        BackupArchiver.archive(
          **archive_arguments(generation, destination), fault_after: ->(step) {
            next unless step == "staged"

            marker = staging.join(BackupArchiver::STAGING_MARKER).binread
            encrypted = staging.join(archive_path(destination).basename).binread
            [ marker, encrypted ].each do |bytes|
              refute_includes bytes, BACKUP_ID
              refute_includes bytes, FINGERPRINT
              refute_includes bytes, "manifest.json"
              refute_includes bytes, "proof.txt"
            end
            raise SimulatedCrash
          }
        )
      end
    end
  end

  test "private plaintext workspace is removed after an interrupted publication" do
    with_generation do |generation, destination|
      plaintext_root = destination.dirname.join("plaintext-scratch").tap(&:mkpath)
      File.chmod 0o700, plaintext_root

      assert_raises(SimulatedCrash) do
        BackupArchiver.archive(
          **archive_arguments(generation, destination),
          plaintext_temporary_directory: plaintext_root,
          fault_after: ->(step) { raise SimulatedCrash if step == "staged" }
        )
      end

      assert_empty plaintext_root.children
    end
  end

  test "production plaintext workspace cannot share the archive destination mount" do
    with_generation do |generation, destination|
      plaintext_root = destination.dirname.join("plaintext-scratch").tap(&:mkpath)
      File.chmod 0o700, plaintext_root
      same_mount = CampfireBackup::MountIdentity::Entry.new(
        mount_id: 100, parent_id: 1, device: "8:1", root: "/", mount_point: "/",
        filesystem_type: "ext4", source: "/dev/sda1"
      ).freeze

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(
          **archive_arguments(generation, destination), expected_environment: "production",
          plaintext_temporary_directory: plaintext_root,
          mount_identity_resolver: ->(_path) { same_mount }
        )
      end

      assert_match "different mount from the archive destination", error.message
      assert_empty plaintext_root.children
      assert_no_publication destination
    end
  end

  test "source symlinks and hard links cannot enter an encrypted publication" do
    with_generation do |generation, destination|
      secret = destination.dirname.join("secret").tap { _1.write "must not be archived" }
      generation.join("leak").make_symlink(secret)

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(**archive_arguments(generation, destination))
      end
      assert_match "symbolic link", error.message
      assert_no_publication destination
    end

    with_generation do |generation, destination|
      File.link generation.join("payload/proof.txt"), generation.join("hard-linked-proof")

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(**archive_arguments(generation, destination))
      end
      assert_match "hard-linked file", error.message
      assert_no_publication destination
    end
  end

  test "source mutation that adds an unmanifested entry is rejected before publication" do
    with_generation do |generation, destination|
      BackupVerifier.stubs(:verify).with do |arguments|
        path = Pathname(arguments.fetch(:generation_path))
        raise "inner archive contains an unmanifested file" if path.join("unmanifested.txt").exist?

        true
      end.returns(true)
      write_archive = BackupArchiver.method(:write_archive)
      BackupArchiver.stubs(:write_archive).with do |file, source|
        source.join("unmanifested.txt").write "not authenticated by the manifest"
        write_archive.call(file, source)
        true
      end.returns(nil)

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(**archive_arguments(generation, destination))
      end

      assert_match "unmanifested file", error.message
      assert_no_publication destination
    end
  end

  test "an encrypted inner statement must match its extracted generation" do
    with_generation do |generation, destination|
      archive = nil
      capture_io { archive = BackupArchiver.archive(**archive_arguments(generation, destination)) }
      replace_inner_statement(archive, destination) do |evidence|
        evidence["schema_version"] += 1
        CampfireBackup::Authentication.sign_statement(evidence, key: AUTHENTICATION_KEY)
      end

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(**archive_arguments(generation, destination))
      end

      assert_match "does not match its extracted generation", error.message
      assert archive.file?
    end
  end

  test "an unknown encrypted inner authentication format is rejected" do
    with_generation do |generation, destination|
      archive = nil
      capture_io { archive = BackupArchiver.archive(**archive_arguments(generation, destination)) }
      replace_inner_statement(archive, destination) do |evidence|
        evidence["format_version"] = 99
        CampfireBackup::Authentication.sign_statement(evidence, key: AUTHENTICATION_KEY)
      end

      error = assert_raises(RuntimeError) do
        BackupArchiver.archive(**archive_arguments(generation, destination))
      end

      assert_match "unsupported format version", error.message
    end
  end

  test "staged and published envelopes are verified as extracted generations" do
    with_generation do |generation, destination|
      verified = []
      BackupVerifier.stubs(:verify).with do |arguments|
        path = Pathname(arguments.fetch(:generation_path))
        verified << {
          source: path.realpath == generation.realpath,
          manifest: path.join("manifest.json").file?
        }
        true
      end.returns(true)

      capture_io { BackupArchiver.archive(**archive_arguments(generation, destination)) }

      assert_equal [ true, false, false ], verified.pluck(:source)
      assert verified.drop(1).all? { _1.fetch(:manifest) }
    end
  end

  private
    def with_generation
      Dir.mktmpdir("campfire-archive-publication") do |directory|
        root = Pathname(directory)
        generation = root.join(BACKUP_ID).tap(&:mkpath)
        payload = {
          format_version: 1,
          backup_id: BACKUP_ID,
          environment: "test",
          installation_fingerprint: FINGERPRINT,
          schema_version: 20251212154340,
          application_version: "1.2.3",
          database: {
            path: "test.sqlite3", bytes: 8, sha256: Digest::SHA256.hexdigest("database")
          },
          files: [
            { path: "proof.txt", bytes: 7, sha256: Digest::SHA256.hexdigest("durable") }
          ],
          source_state: {
            format_version: 1,
            backup_id: BACKUP_ID,
            environment: "test",
            installation_fingerprint: FINGERPRINT,
            schema_version: 20251212154340,
            database: {
              path: "db/test.sqlite3", bytes: 8, sha256: Digest::SHA256.hexdigest("database")
            },
            database_sidecars: [
              { path: "db/test.sqlite3-journal", required_state: "absent" },
              { path: "db/test.sqlite3-shm", required_state: "absent-or-regular-transient" },
              { path: "db/test.sqlite3-wal", required_state: "absent-or-empty" }
            ],
            storage_files: [
              { path: "proof.txt", bytes: 7, sha256: Digest::SHA256.hexdigest("durable") }
            ]
          }
        }
        generation.join("manifest.json").write JSON.pretty_generate(
          CampfireBackup::Authentication.sign_manifest(payload, key: AUTHENTICATION_KEY)
        )
        generation.join("payload").mkpath
        generation.join("payload/proof.txt").write "durable"
        generation.join("test.sqlite3").write "database"
        yield generation, root.join("archives")
      end
    end

    def archive_arguments(generation, destination)
      {
        generation_path: generation,
        destination_directory: destination,
        expected_installation_fingerprint: FINGERPRINT,
        expected_environment: "test",
        authentication_key: AUTHENTICATION_KEY,
        encryption_keyring: encryption_keyring
      }
    end

    def encryption_keyring
      CampfireBackup::BackupEncryption::Keyring.new(
        active_id: ENCRYPTION_KEY_ID, active_key: ENCRYPTION_KEY
      )
    end

    def archive_path(destination)
      destination.join("campfire-#{BACKUP_ID}.campfire-backup")
    end

    def staging_path(destination)
      destination.join(".campfire-#{BACKUP_ID}.archive-staging")
    end

    def assert_no_publication(destination)
      entries = destination.children.reject do |path|
        path.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
      end
      assert_empty entries
    end

    def replace_inner_statement(archive, destination)
      replacement = destination.join("replacement.campfire-backup")
      CampfireBackup::BackupEncryption.with_decrypted_archive(
        archive, keyring: encryption_keyring, temporary_directory: destination
      ) do |plaintext_archive, authentication, _envelope|
        evidence = CampfireBackup::Authentication.verify_statement!(
          JSON.parse(authentication), key: AUTHENTICATION_KEY
        )
        statement = yield evidence
        File.open(
          replacement, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600
        ) do |encrypted|
          CampfireBackup::BackupEncryption.encrypt_archive(
            archive_io: plaintext_archive, authentication: JSON.generate(statement),
            destination_io: encrypted, keyring: encryption_keyring
          )
        end
      end
      archive.unlink
      File.rename replacement, archive
    end
end
