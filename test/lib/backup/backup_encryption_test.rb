require "test_helper"
require "delegate"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require Rails.root.join("lib/campfire_backup/backup_encryption")

class BackupEncryptionTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  CURRENT_KEY = "current backup encryption key".ljust(32, "!")
  OLD_KEY = "retired backup encryption key".ljust(32, "!")
  WRONG_KEY = "wrong backup encryption key".ljust(32, "!")

  class TrackingIO < SimpleDelegator
    attr_reader :maximum_read

    def read(length = nil, *)
      @maximum_read = [ @maximum_read.to_i, length.to_i ].max
      super
    end
  end

  test "streams a large archive through encryption and authenticated decryption" do
    with_private_directory do |directory|
      plaintext = directory.join("large.tar.gz")
      encrypted = directory.join("large.campfire-backup")
      expected_digest = Digest::SHA256.new
      File.open(plaintext, "wb", 0o600) do |file|
        12.times do |index|
          chunk = index.to_s.ljust(CampfireBackup::BackupEncryption::CHUNK_BYTES, "x")
          file.write chunk
          expected_digest << chunk
        end
      end

      encrypt_reads = nil
      File.open(plaintext, "rb") do |source|
        tracked_source = TrackingIO.new(source)
        write_envelope encrypted, tracked_source, authentication: "authenticated statement"
        encrypt_reads = tracked_source.maximum_read
      end

      decrypt_reads = nil
      File.open(encrypted, "rb") do |source|
        tracked_source = TrackingIO.new(source)
        CampfireBackup::BackupEncryption.decrypt_archive(
          source_io: tracked_source, keyring: current_keyring,
          temporary_directory: directory
        ) do |archive, authentication, envelope|
          assert_instance_of CampfireBackup::BackupEncryption::ArchiveView, archive
          assert_equal "authenticated statement", authentication
          assert_equal "current-2026-08", envelope.fetch(:key_id)
          actual_digest = Digest::SHA256.new
          while (chunk = archive.read(CampfireBackup::BackupEncryption::CHUNK_BYTES))
            actual_digest << chunk
          end
          assert_equal expected_digest.hexdigest, actual_digest.hexdigest
        end
        decrypt_reads = tracked_source.maximum_read
      end

      assert_operator encrypt_reads, :<=, CampfireBackup::BackupEncryption::CHUNK_BYTES
      assert_operator decrypt_reads, :<=, CampfireBackup::BackupEncryption::CHUNK_BYTES
    end
  end

  test "selects an explicitly identified retired key for old backups" do
    with_envelope(keyring: old_keyring) do |encrypted, directory|
      restore_keyring = CampfireBackup::BackupEncryption::Keyring.new(
        active_id: "current-2026-08", active_key: CURRENT_KEY,
        previous_keys: { "retired-2026-01" => OLD_KEY }
      )
      selected = nil

      CampfireBackup::BackupEncryption.with_decrypted_archive(
        encrypted, keyring: restore_keyring, temporary_directory: directory
      ) do |archive, _authentication, envelope|
        selected = envelope.fetch(:key_id)
        assert_equal "archive contents", archive.read
      end

      assert_equal "retired-2026-01", selected
    end
  end

  test "rejects a wrong or unavailable key without leaving plaintext" do
    with_envelope do |encrypted, directory|
      plaintext_stage = directory.join("private-stage").tap(&:mkpath)
      File.chmod 0o700, plaintext_stage

      error = assert_raises(RuntimeError) do
        CampfireBackup::BackupEncryption.with_decrypted_archive(
          encrypted,
          keyring: CampfireBackup::BackupEncryption::Keyring.new(
            active_id: "current-2026-08", active_key: WRONG_KEY
          ),
          temporary_directory: plaintext_stage
        ) { flunk "wrong-key plaintext was yielded" }
      end

      assert_match "authentication failed", error.message
      assert_empty plaintext_stage.children

      error = assert_raises(RuntimeError) do
        CampfireBackup::BackupEncryption.with_decrypted_archive(
          encrypted,
          keyring: CampfireBackup::BackupEncryption::Keyring.new(
            active_id: "other-key", active_key: WRONG_KEY
          ),
          temporary_directory: plaintext_stage
        ) { flunk "unavailable-key plaintext was yielded" }
      end
      assert_match "key ID is not available: current-2026-08", error.message
      assert_empty plaintext_stage.children
    end
  end

  test "authenticates every parseable header byte" do
    with_envelope do |encrypted, directory|
      original = encrypted.binread
      nonce_offset = CampfireBackup::BackupEncryption::HEADER_BYTES + "current-2026-08".bytesize
      bytes = original.dup
      bytes.setbyte(nonce_offset, bytes.getbyte(nonce_offset) ^ 0x01)
      corrupted = directory.join("header-corrupt.campfire-backup")
      corrupted.binwrite bytes
      File.chmod 0o600, corrupted

      error = assert_raises(RuntimeError) do
        decrypt corrupted, directory
      end
      assert_match "authentication failed", error.message

      key_id_corrupt = directory.join("key-id-corrupt.campfire-backup")
      key_id_bytes = original.dup
      key_id_bytes.setbyte(CampfireBackup::BackupEncryption::HEADER_BYTES, "x".ord)
      key_id_corrupt.binwrite key_id_bytes
      File.chmod 0o600, key_id_corrupt
      keyring = CampfireBackup::BackupEncryption::Keyring.new(
        active_id: "current-2026-08", active_key: CURRENT_KEY,
        previous_keys: { "xurrent-2026-08" => CURRENT_KEY }
      )
      error = assert_raises(RuntimeError) do
        CampfireBackup::BackupEncryption.with_decrypted_archive(
          key_id_corrupt, keyring:, temporary_directory: directory
        ) { flunk "a modified authenticated key ID was accepted" }
      end
      assert_match "authentication failed", error.message
    end
  end

  test "rejects invalid bounded header lengths before reading variable data" do
    with_envelope do |encrypted, directory|
      bytes = encrypted.binread
      bytes[12, 2] = [ CampfireBackup::BackupEncryption::MAX_KEY_ID_BYTES + 1 ].pack("n")
      corrupted = directory.join("unbounded-header.campfire-backup")
      corrupted.binwrite bytes
      File.chmod 0o600, corrupted

      error = assert_raises(RuntimeError) { decrypt corrupted, directory }
      assert_match "header lengths are invalid", error.message
    end
  end

  test "bounds the complete GCM bundle at an exact practical limit" do
    encryption = CampfireBackup::BackupEncryption

    assert_operator encryption::MAX_PAYLOAD_BYTES, :<, encryption::GCM_MAX_PLAINTEXT_BYTES
    assert_equal encryption::MAX_PAYLOAD_BYTES,
      encryption.send(
        :checked_payload_size, encryption::BUNDLE_HEADER_BYTES, 1,
        encryption::MAX_ARCHIVE_BYTES
      )
    error = assert_raises(RuntimeError) do
      encryption.send(
        :checked_payload_size, encryption::BUNDLE_HEADER_BYTES, 1,
        encryption::MAX_ARCHIVE_BYTES + 1
      )
    end
    assert_match "payload is too large", error.message

    key_id = "boundary-key"
    fixed = [
      encryption::MAGIC, encryption::FORMAT_VERSION, encryption::CIPHER_AES_256_GCM,
      encryption::FLAGS, key_id.bytesize, encryption::NONCE_BYTES,
      encryption::TAG_BYTES, encryption::MAX_PAYLOAD_BYTES
    ].pack(encryption::HEADER_PACK)
    header = encryption.send(
      :read_header!, StringIO.new(fixed + key_id + ("n" * encryption::NONCE_BYTES))
    )
    assert_equal encryption::MAX_PAYLOAD_BYTES, header.fetch(:payload_bytes)

    oversized = fixed.dup
    oversized[-8, 8] = [ encryption::MAX_PAYLOAD_BYTES + 1 ].pack("Q>")
    assert_raises(RuntimeError) do
      encryption.send(
        :read_header!, StringIO.new(oversized + key_id + ("n" * encryption::NONCE_BYTES))
      )
    end
  end

  test "rejects an oversized payload header before capacity checks or staging" do
    with_envelope do |encrypted, directory|
      bytes = encrypted.binread
      bytes[16, 8] = [ CampfireBackup::BackupEncryption::MAX_PAYLOAD_BYTES + 1 ].pack("Q>")
      encrypted.binwrite bytes
      CampfireBackup::BackupEncryption.expects(:available_bytes).never
      CampfireBackup::BackupEncryption.expects(:with_unlinked_temporary_file).never

      error = assert_raises(RuntimeError) { decrypt encrypted, directory }

      assert_match "header lengths are invalid", error.message
    end
  end

  test "accepts the exact bounded legacy file size and rejects one byte more" do
    with_private_directory do |directory|
      bounded = directory.join("bounded-legacy")
      File.open(bounded, "wb") do |file|
        file.truncate CampfireBackup::BackupEncryption::MAX_ARCHIVE_BYTES
      end
      size = CampfireBackup::BackupEncryption.open_independent_file(
        bounded, description: "Legacy plaintext backup archive",
        maximum_bytes: CampfireBackup::BackupEncryption::MAX_ARCHIVE_BYTES
      ) { _1.stat.size }
      assert_equal CampfireBackup::BackupEncryption::MAX_ARCHIVE_BYTES, size

      File.open(bounded, "r+b") do |file|
        file.truncate CampfireBackup::BackupEncryption::MAX_ARCHIVE_BYTES + 1
      end
      error = assert_raises(RuntimeError) do
        CampfireBackup::BackupEncryption.open_independent_file(
          bounded, description: "Legacy plaintext backup archive",
          maximum_bytes: CampfireBackup::BackupEncryption::MAX_ARCHIVE_BYTES
        ) { flunk "oversized legacy archive was opened" }
      end
      assert_match "safe size limit", error.message
    end
  end

  test "preflights the one-copy plaintext staging requirement before decryption" do
    with_envelope do |encrypted, directory|
      payload_bytes = CampfireBackup::BackupEncryption.envelope_metadata(encrypted).fetch(:payload_bytes)
      required = CampfireBackup::BackupEncryption.required_staging_bytes(payload_bytes)
      CampfireBackup::BackupEncryption.stubs(:available_bytes).returns(required - 1)
      CampfireBackup::BackupEncryption.expects(:with_unlinked_temporary_file).never

      error = assert_raises(RuntimeError) { decrypt encrypted, directory }

      assert_match "Insufficient free space", error.message
    end
  end

  test "accepts the exact one-copy plaintext staging requirement" do
    with_envelope do |encrypted, directory|
      payload_bytes = CampfireBackup::BackupEncryption.envelope_metadata(encrypted).fetch(:payload_bytes)
      required = CampfireBackup::BackupEncryption.required_staging_bytes(payload_bytes)
      CampfireBackup::BackupEncryption.stubs(:available_bytes).returns(required)

      assert_equal "archive contents", decrypted_contents(encrypted, directory)
    end
  end

  test "the portable create-unlink fallback durably removes its name before plaintext and cleans up" do
    with_private_directory do |directory|
      CampfireBackup::BackupEncryption.stubs(:open_anonymous_temporary_file).returns(nil)
      CampfireBackup::BackupEncryption.expects(:flush_directory).with(directory).twice

      assert_raises(RuntimeError) do
        CampfireBackup::BackupEncryption.with_unlinked_temporary_file(directory) do |file|
          assert_empty directory.children
          file.write "recoverable plaintext"
          raise "simulated interruption"
        end
      end

      assert_empty directory.children
    end
  end

  test "prefers an already anonymous temporary descriptor when the filesystem supports it" do
    with_private_directory do |directory|
      path = directory.join("anonymous-simulation")
      file = File.open(path, File::RDWR | File::CREAT | File::EXCL, 0o600)
      path.unlink
      CampfireBackup::BackupEncryption.stubs(:open_anonymous_temporary_file).returns(file)
      CampfireBackup::BackupEncryption.expects(:with_create_unlink_temporary_file).never

      CampfireBackup::BackupEncryption.with_unlinked_temporary_file(directory) do |temporary|
        assert_same file, temporary
        assert_predicate temporary.stat.nlink, :zero?
      end

      assert_predicate file, :closed?
    end
  end

  test "rejects ciphertext and tag corruption" do
    with_envelope do |encrypted, directory|
      original = encrypted.binread
      header_bytes = CampfireBackup::BackupEncryption::HEADER_BYTES +
        "current-2026-08".bytesize + CampfireBackup::BackupEncryption::NONCE_BYTES
      {
        "ciphertext" => header_bytes + 3,
        "tag" => original.bytesize - 1
      }.each do |kind, offset|
        bytes = original.dup
        bytes.setbyte(offset, bytes.getbyte(offset) ^ 0x80)
        corrupted = directory.join("#{kind}-corrupt.campfire-backup")
        corrupted.binwrite bytes
        File.chmod 0o600, corrupted

        error = assert_raises(RuntimeError, kind) { decrypt corrupted, directory }
        assert_match "authentication failed", error.message, kind
      end
    end
  end

  test "rejects header payload and tag truncation plus trailing bytes" do
    with_envelope do |encrypted, directory|
      original = encrypted.binread
      [ 1, CampfireBackup::BackupEncryption::HEADER_BYTES + 2, original.bytesize - 1 ].each do |size|
        truncated = directory.join("truncated-#{size}.campfire-backup")
        truncated.binwrite original.byteslice(0, size)
        File.chmod 0o600, truncated

        error = assert_raises(RuntimeError, size.to_s) { decrypt truncated, directory }
        assert_match "truncated", error.message, size.to_s
      end

      trailing = directory.join("trailing.campfire-backup")
      trailing.binwrite(original + "trailing")
      File.chmod 0o600, trailing
      error = assert_raises(RuntimeError) { decrypt trailing, directory }
      assert_match "trailing bytes", error.message
    end
  end

  test "uses a fresh GCM nonce for every archive" do
    with_private_directory do |directory|
      first = create_envelope directory.join("first.campfire-backup"), directory
      second = create_envelope directory.join("second.campfire-backup"), directory
      first_metadata = CampfireBackup::BackupEncryption.envelope_metadata(first)
      second_metadata = CampfireBackup::BackupEncryption.envelope_metadata(second)

      refute_equal first_metadata.fetch(:nonce), second_metadata.fetch(:nonce)
      refute_equal first.binread, second.binread
    end
  end

  test "keeps filenames statements and digests out of the envelope plaintext" do
    with_private_directory do |directory|
      secret_archive = "manifest.json\nproduction.sqlite3\nfiles/private-message.txt"
      secret_statement = JSON.generate(
        archive: { filename: "private-name.tar.gz", sha256: "d" * 64 }
      )
      encrypted = directory.join("confidential.campfire-backup")
      plaintext = directory.join("plain").tap { _1.binwrite secret_archive }
      File.chmod 0o600, plaintext
      File.open(plaintext, "rb") do |source|
        write_envelope encrypted, source, authentication: secret_statement
      end
      envelope = encrypted.binread

      refute_includes envelope, "manifest.json"
      refute_includes envelope, "production.sqlite3"
      refute_includes envelope, "private-message.txt"
      refute_includes envelope, "private-name.tar.gz"
      refute_includes envelope, "d" * 64
    end
  end

  test "rejects symbolic and hard-linked encrypted sources" do
    with_envelope do |encrypted, directory|
      symlink = directory.join("linked.campfire-backup")
      symlink.make_symlink encrypted
      error = assert_raises(RuntimeError) do
        CampfireBackup::BackupEncryption.envelope_metadata(symlink)
      end
      assert_match "independent regular file", error.message

      hardlink = directory.join("hard-linked.campfire-backup")
      File.link encrypted, hardlink
      error = assert_raises(RuntimeError) do
        CampfireBackup::BackupEncryption.envelope_metadata(encrypted)
      end
      assert_match "independent regular file", error.message
    end
  end

  test "decrypts only the descriptor opened before a source pathname race" do
    with_private_directory do |directory|
      trusted = create_envelope(
        directory.join("backup.campfire-backup"), directory, contents: "trusted"
      )
      replacement = create_envelope(
        directory.join("replacement.campfire-backup"), directory, contents: "replacement"
      )
      moved = directory.join("moved.campfire-backup")

      CampfireBackup::BackupEncryption.open_encrypted_file(trusted) do |source|
        File.rename trusted, moved
        File.rename replacement, trusted
        CampfireBackup::BackupEncryption.decrypt_archive(
          source_io: source, keyring: current_keyring, temporary_directory: directory
        ) do |archive, _authentication, _envelope|
          assert_equal "trusted", archive.read
        end
      end
      assert_equal "replacement", decrypted_contents(trusted, directory)
    end
  end

  test "decodes a bounded rotation keyring and scrubs every key environment entry" do
    environment = {
      "unrelated" => "preserve",
      "BACKUP_ENCRYPTION_KEY_ID" => "current-2026-08",
      "BACKUP_ENCRYPTION_KEY" => Base64.strict_encode64(CURRENT_KEY),
      "BACKUP_ENCRYPTION_PREVIOUS_KEYS" => JSON.generate(
        "retired-2026-01" => Base64.strict_encode64(OLD_KEY)
      )
    }

    keyring = CampfireBackup::BackupEncryption.keyring_from_env!(environment)

    assert_equal %w[ current-2026-08 retired-2026-01 ], keyring.key_ids
    assert_equal CURRENT_KEY, keyring.key_for("current-2026-08")
    assert_equal OLD_KEY, keyring.key_for("retired-2026-01")
    assert_equal({ "unrelated" => "preserve" }, environment)
  ensure
    keyring&.clear!
  end

  test "requires an exact 256-bit key and a separate authentication key" do
    environment = {
      "BACKUP_ENCRYPTION_KEY_ID" => "current",
      "BACKUP_ENCRYPTION_KEY" => Base64.strict_encode64("short")
    }
    error = assert_raises(RuntimeError) do
      CampfireBackup::BackupEncryption.keyring_from_env!(environment)
    end
    assert_match "exactly 32 random bytes", error.message
    assert_empty environment

    error = assert_raises(RuntimeError) do
      current_keyring.assert_distinct_from! CURRENT_KEY
    end
    assert_match "must be separate", error.message
  end

  test "admin generator emits a named 256-bit key" do
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, Rails.root.join("script/admin/generate-backup-encryption-key").to_s,
      "escrow-2026-08"
    )

    assert status.success?, stderr
    values = stdout.lines.to_h { _1.strip.split("=", 2) }
    assert_equal "escrow-2026-08", values.fetch("BACKUP_ENCRYPTION_KEY_ID")
    assert_equal 32, Base64.strict_decode64(values.fetch("BACKUP_ENCRYPTION_KEY")).bytesize
  end

  private
    def current_keyring
      CampfireBackup::BackupEncryption::Keyring.new(
        active_id: "current-2026-08", active_key: CURRENT_KEY
      )
    end

    def old_keyring
      CampfireBackup::BackupEncryption::Keyring.new(
        active_id: "retired-2026-01", active_key: OLD_KEY
      )
    end

    def with_private_directory
      Dir.mktmpdir("campfire-backup-encryption") do |name|
        directory = Pathname(name)
        File.chmod 0o700, directory
        yield directory
      end
    end

    def with_envelope(keyring: current_keyring)
      with_private_directory do |directory|
        yield create_envelope(directory.join("backup.campfire-backup"), directory, keyring:), directory
      end
    end

    def create_envelope(path, directory, contents: "archive contents", keyring: current_keyring)
      plaintext = directory.join("plaintext-#{SecureRandom.hex(4)}")
      plaintext.binwrite contents
      File.chmod 0o600, plaintext
      File.open(plaintext, "rb") do |source|
        write_envelope path, source, keyring:, authentication: "statement"
      end
      plaintext.unlink
      path
    end

    def write_envelope(path, source, keyring: current_keyring, authentication: "statement")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |destination|
        CampfireBackup::BackupEncryption.encrypt_archive(
          archive_io: source, authentication:, destination_io: destination, keyring:
        )
      end
    end

    def decrypt(path, directory)
      CampfireBackup::BackupEncryption.with_decrypted_archive(
        path, keyring: current_keyring, temporary_directory: directory
      ) { true }
    end

    def decrypted_contents(path, directory)
      contents = nil
      CampfireBackup::BackupEncryption.with_decrypted_archive(
        path, keyring: current_keyring, temporary_directory: directory
      ) { |archive,| contents = archive.read }
      contents
    end
end
