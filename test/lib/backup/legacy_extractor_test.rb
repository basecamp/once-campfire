require "test_helper"
require "tmpdir"
require "rubygems/package"
require "zlib"

load Rails.root.join("script/admin/extract-backup") unless defined?(BackupExtractor)

class LegacyExtractorTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  BACKUP_ID = "20260731T120000Z-0123456789abcdef"
  AUTHENTICATION_KEY = "legacy archive authentication key".ljust(32, "!")
  FINGERPRINT = "f" * 64

  test "explicitly extracts a bounded authenticated released plaintext archive" do
    with_legacy_archive do |archive, authentication, destination|
      stdout = capture_io do
        BackupExtractor.extract(
          **extract_arguments(archive, authentication, destination)
        )
      end.first

      report = JSON.parse(stdout)
      assert_equal "legacy-plaintext", report.fetch("format")
      assert_nil report.fetch("encryption_key_id")
      assert_equal "released backup", destination.join(BACKUP_ID, "payload/proof.txt").read
    end
  end

  test "authenticates legacy bytes before archive parsing or extraction" do
    with_legacy_archive do |archive, authentication, destination|
      archive.open("ab") { _1.write "tampered" }
      BackupExtractor.expects(:inspect_archive).never

      error = assert_raises(RuntimeError) do
        BackupExtractor.extract(**extract_arguments(archive, authentication, destination))
      end

      assert_match(/metadata does not match|authentication does not match/, error.message)
      assert_empty destination.children.reject {
        _1.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
      }
    end
  end

  test "rejects an oversized legacy archive before authentication or staging" do
    Dir.mktmpdir("campfire-legacy-archive-limit") do |directory|
      root = Pathname(directory)
      archive = root.join("oversized").tap do |path|
        File.open(path, "wb") { _1.truncate(CampfireBackup::BackupEncryption::MAX_ARCHIVE_BYTES + 1) }
      end
      authentication = root.join("authentication").tap { _1.write "{}" }
      destination = root.join("restore")
      CampfireBackup::Authentication.expects(:verify_archive!).never
      CampfireBackup::BackupEncryption.expects(:with_unlinked_temporary_file).never

      error = assert_raises(RuntimeError) do
        BackupExtractor.extract(**extract_arguments(archive, authentication, destination))
      end

      assert_match "safe size limit", error.message
    end
  end

  test "command line requires either the encrypted or explicit legacy contract" do
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, Rails.root.join("script/admin/extract-backup").to_s, "ambiguous"
    )

    assert_empty stdout
    assert_equal 64, status.exitstatus
    assert_includes stderr, "extract-backup ENCRYPTED_BACKUP DESTINATION"
    assert_includes stderr, "--legacy-plaintext ARCHIVE AUTHENTICATION_STATEMENT DESTINATION"
  end

  private
    def with_legacy_archive
      Dir.mktmpdir("campfire-legacy-extractor") do |directory|
        root = Pathname(directory)
        archive = root.join("campfire-#{BACKUP_ID}.tar.gz")
        Zlib::GzipWriter.open(archive.to_s) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            tar.mkdir BACKUP_ID, 0o700
            add_file tar, "#{BACKUP_ID}/manifest.json", "{}"
            tar.mkdir "#{BACKUP_ID}/payload", 0o700
            add_file tar, "#{BACKUP_ID}/payload/proof.txt", "released backup"
          end
        end
        statement = CampfireBackup::Authentication.sign_statement({
          format_version: CampfireBackup::Authentication::ARCHIVE_FORMAT_VERSION,
          kind: "campfire-backup-archive",
          backup_id: BACKUP_ID,
          environment: "test",
          installation_fingerprint: FINGERPRINT,
          archive: {
            filename: archive.basename.to_s,
            bytes: archive.size,
            sha256: Digest::SHA256.file(archive).hexdigest
          }
        }, key: AUTHENTICATION_KEY)
        authentication = root.join("campfire-#{BACKUP_ID}.authentication.json")
        authentication.write JSON.generate(statement)
        yield archive, authentication, root.join("restore")
      end
    end

    def extract_arguments(archive, authentication, destination)
      {
        archive_path: archive, legacy_authentication_path: authentication,
        destination_directory: destination, backup_id: BACKUP_ID,
        expected_installation_fingerprint: FINGERPRINT, expected_environment: "test",
        authentication_key: AUTHENTICATION_KEY
      }
    end

    def add_file(tar, name, contents)
      tar.add_file_simple(name, 0o600, contents.bytesize) { _1.write(contents) }
    end
end
