require "test_helper"
require "tmpdir"
require "rubygems/package"
require "zlib"

load Rails.root.join("script/admin/extract-backup") unless defined?(BackupExtractor)

class BackupExtractorTest < ActiveSupport::TestCase
  BACKUP_ID = "20260731T120000Z-0123456789abcdef"
  ENCRYPTION_KEY = "extractor encryption key".ljust(32, "!")
  OLD_ENCRYPTION_KEY = "old extractor encryption key".ljust(32, "!")

  setup do
    CampfireBackup::Authentication.stubs(:verify_archive!).returns(true)
  end

  test "extracts one regular backup tree into an empty directory" do
    with_archive do |archive, destination|
      write_archive(archive) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "{}"
        add_file tar, "#{BACKUP_ID}/payload/files/message.txt", "hello"
      end

      capture_io do
        extract archive, destination
      end

      assert_equal "hello", destination.join(BACKUP_ID, "payload/files/message.txt").read
      assert_equal 0o600, destination.join(BACKUP_ID, "manifest.json").stat.mode & 0o777
    end
  end

  test "rejects links before extracting any entry" do
    with_archive do |archive, destination|
      write_archive(archive) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "{}"
        tar.add_symlink "#{BACKUP_ID}/escape", "/tmp", 0o777
      end

      assert_raises(RuntimeError) do
        extract archive, destination
      end
      assert_no_extracted_content destination
    end
  end

  test "does not inspect or publish GCM-authenticated plaintext before inner HMAC verification" do
    with_archive do |archive, destination|
      write_archive(archive) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "not HMAC authenticated"
      end
      CampfireBackup::Authentication.stubs(:verify_archive!).raises("inner HMAC failed")
      BackupExtractor.expects(:inspect_archive).never

      error = assert_raises(RuntimeError) { extract archive, destination }

      assert_match "inner HMAC failed", error.message
      assert_no_extracted_content destination
    end
  end

  test "fails closed when directory durability is unsupported" do
    with_archive do |archive, destination|
      write_archive(archive) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "{}"
      end
      BackupExtractor.stubs(:flush_directory).raises(Errno::ENOTSUP)

      assert_raises(Errno::ENOTSUP) { extract archive, destination }
      assert_no_extracted_content destination
    end
  end

  test "detects destination replacement without leaving a lock in either target" do
    with_archive do |archive, destination|
      write_archive(archive) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "{}"
      end
      original = destination.dirname.join("original-restore")

      error = assert_raises(RuntimeError) do
        BackupExtractor.extract(
          archive_path: archive, destination_directory: destination, backup_id: BACKUP_ID,
          expected_installation_fingerprint: "f" * 64, expected_environment: "test",
          authentication_key: "k" * 32, encryption_keyring: encryption_keyring,
          fault_after: ->(step) {
            if step == "claimed"
              File.rename destination, original
              destination.mkpath
            end
          }
        )
      end

      assert_match "target changed", error.message
      assert_no_extracted_content destination
      assert_no_extracted_content original
    end
  end

  test "extracts only the pinned authenticated bytes when the source pathname is replaced" do
    with_archive do |archive, destination|
      replacement = archive.dirname.join("replacement.tar.gz")
      write_archive(archive) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "trusted"
      end
      write_archive(replacement) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "altered"
      end

      capture_io do
        BackupExtractor.extract(
          archive_path: archive, destination_directory: destination, backup_id: BACKUP_ID,
          expected_installation_fingerprint: "f" * 64, expected_environment: "test",
          authentication_key: "k" * 32, encryption_keyring: encryption_keyring,
          fault_after: ->(step) {
            File.rename replacement, archive if step == "authenticated"
          }
        )
      end

      assert_equal "trusted", destination.join(BACKUP_ID, "manifest.json").read
      assert_empty destination.children.select {
        _1.basename.to_s.start_with?(".campfire-authenticated-archive-")
      }
    end
  end

  test "never gives decrypted plaintext a pathname in the destination" do
    with_archive do |archive, destination|
      write_archive(archive) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "trusted"
      end

      capture_io do
        BackupExtractor.extract(
          archive_path: archive, destination_directory: destination, backup_id: BACKUP_ID,
          expected_installation_fingerprint: "f" * 64, expected_environment: "test",
          authentication_key: "k" * 32, encryption_keyring: encryption_keyring,
          fault_after: ->(step) {
            if step == "authenticated"
              visible = destination.children.reject do |path|
                path.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
              end
              assert_empty visible
            end
          }
        )
      end

      assert_equal "trusted", destination.join(BACKUP_ID, "manifest.json").read
    end
  end

  test "restores an old-key envelope selected by its key ID" do
    with_archive do |archive, destination|
      old_keyring = CampfireBackup::BackupEncryption::Keyring.new(
        active_id: "extractor-retired", active_key: OLD_ENCRYPTION_KEY
      )
      write_archive(archive, keyring: old_keyring) do |tar|
        tar.mkdir BACKUP_ID, 0o700
        add_file tar, "#{BACKUP_ID}/manifest.json", "old-key backup"
      end
      restore_keyring = CampfireBackup::BackupEncryption::Keyring.new(
        active_id: "extractor-test", active_key: ENCRYPTION_KEY,
        previous_keys: { "extractor-retired" => OLD_ENCRYPTION_KEY }
      )

      capture_io do
        BackupExtractor.extract(
          archive_path: archive, destination_directory: destination, backup_id: BACKUP_ID,
          expected_installation_fingerprint: "f" * 64, expected_environment: "test",
          authentication_key: "k" * 32, encryption_keyring: restore_keyring
        )
      end

      assert_equal "old-key backup", destination.join(BACKUP_ID, "manifest.json").read
    end
  end

  private
    def extract(archive, destination)
      BackupExtractor.extract(
        archive_path: archive,
        destination_directory: destination,
        backup_id: BACKUP_ID,
        expected_installation_fingerprint: "f" * 64,
        expected_environment: "test",
        authentication_key: "k" * 32,
        encryption_keyring: encryption_keyring
      )
    end

    def with_archive
      Dir.mktmpdir("campfire-backup-extractor") do |directory|
        root = Pathname(directory)
        yield root.join("backup.tar.gz"), root.join("restore")
      end
    end

    def write_archive(path, keyring: encryption_keyring)
      plaintext = Pathname("#{path}.plaintext-#{SecureRandom.hex(4)}")
      Zlib::GzipWriter.open(plaintext.to_s) do |gzip|
        Gem::Package::TarWriter.new(gzip) { yield _1 }
      end
      File.open(plaintext, "rb") do |source|
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |destination|
          CampfireBackup::BackupEncryption.encrypt_archive(
            archive_io: source, authentication: "{}", destination_io: destination,
            keyring:
          )
        end
      end
    ensure
      plaintext&.unlink if plaintext&.exist?
    end

    def add_file(tar, name, contents)
      tar.add_file_simple(name, 0o600, contents.bytesize) { _1.write(contents) }
    end

    def assert_no_extracted_content(destination)
      entries = destination.children.reject do |path|
        path.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
      end
      assert_empty entries
    end

    def encryption_keyring
      CampfireBackup::BackupEncryption::Keyring.new(
        active_id: "extractor-test", active_key: ENCRYPTION_KEY
      )
    end
end
