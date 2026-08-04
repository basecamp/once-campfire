require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

load Rails.root.join("script/admin/prepare-backup") unless defined?(Backup)
load Rails.root.join("script/admin/verify-backup") unless defined?(BackupVerifier)
load Rails.root.join("script/admin/archive-backup") unless defined?(BackupArchiver)
load Rails.root.join("script/admin/extract-backup") unless defined?(BackupExtractor)
load Rails.root.join("script/admin/install-backup") unless defined?(BackupInstaller)

class BackupTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  AUTHENTICATION_KEY = Base64.strict_encode64("backup-test-key".ljust(32, "!"))
  ENCRYPTION_KEY = "backup encryption test key".ljust(32, "!")

  setup do
    @previous_authentication_key = ENV["BACKUP_AUTHENTICATION_KEY"]
    ENV["BACKUP_AUTHENTICATION_KEY"] = AUTHENTICATION_KEY
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    CampfireBackup::RedisValidator.stubs(:validate!)
  end

  teardown do
    if @previous_authentication_key
      ENV["BACKUP_AUTHENTICATION_KEY"] = @previous_authentication_key
    else
      ENV.delete "BACKUP_AUTHENTICATION_KEY"
    end
  end

  test "publishes and verifies an immutable database and file generation" do
    with_storage do |storage, backups|
      stored_file = storage.join("files", "room", "attachment.txt")
      stored_file.dirname.mkpath
      stored_file.write "irreplaceable attachment"
      File.chmod 0o666, stored_file
      redis_file = storage.join("redis", "appendonly.aof")
      redis_file.dirname.mkpath
      redis_file.write "durable queue state"
      File.chmod 0o600, redis_file
      CampfireBackup::RedisValidator.stubs(:validate!)

      output = capture_io do
        Backup.create(
          destination_directory: backups, storage_directory: storage,
          confirmation: Backup::QUIESCENCE_CONFIRMATION,
          database_relative_path: "db/test.sqlite3"
        )
      end.first.then { JSON.parse(_1) }
      generation = Pathname(output.fetch("path"))
      manifest = JSON.parse(generation.join("manifest.json").read)
      snapshot = generation.join(manifest.dig("database", "path"))
      copied_file = generation.join("payload", "files", "room", "attachment.txt")

      assert_equal generation.realpath, backups.join("latest").realpath
      assert_equal Digest::SHA256.file(snapshot).hexdigest, manifest.dig("database", "sha256")
      assert_equal %w[ files/room/attachment.txt installation-identifier redis/appendonly.aof ], manifest.fetch("files").pluck("path")
      assert_equal "irreplaceable attachment", copied_file.read
      assert_equal "durable queue state", generation.join("payload", "redis", "appendonly.aof").read
      assert_equal 0o750, generation.stat.mode & 0o777
      assert_equal Process.gid, generation.stat.gid
      assert_equal 0o640, copied_file.stat.mode & 0o777
      assert_equal Process.gid, copied_file.stat.gid
      assert_equal 0o640, generation.join("payload", "redis", "appendonly.aof").stat.mode & 0o777
      stored_file.write "changed after publication"
      capture_io do
        assert BackupVerifier.verify(
          generation_path: backups.join("latest"),
          expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
          expected_environment: "test"
        )
      end
    end
  end

  test "verification rejects corruption and the wrong installation without mutating other files" do
    with_storage do |storage, backups|
      marker = storage.join("current-state.txt")
      marker.write "untouched"
      output = capture_io do
        Backup.create(
          destination_directory: backups, storage_directory: storage,
          confirmation: Backup::QUIESCENCE_CONFIRMATION,
          database_relative_path: "db/test.sqlite3"
        )
      end.first.then { JSON.parse(_1) }
      generation = Pathname(output.fetch("path"))
      manifest = JSON.parse(generation.join("manifest.json").read)

      assert_raises(RuntimeError) do
        BackupVerifier.verify(
          generation_path: generation,
          expected_installation_fingerprint: "0" * 64,
          expected_environment: "test"
        )
      end

      database_path = generation.join(manifest.dig("database", "path"))
      File.open(database_path, "ab") { _1.write("corrupt") }
      assert_raises(RuntimeError) do
        BackupVerifier.verify(
          generation_path: generation,
          expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
          expected_environment: "test"
        )
      end
      assert_equal "untouched", marker.read
    end
  end

  test "standalone verification checks the database consumed by restore" do
    with_storage do |storage, backups|
      stored_file = storage.join("files", "room", "attachment.txt")
      stored_file.dirname.mkpath
      stored_file.write "standalone verification"
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))
      tools = storage.dirname.join("tools").tap(&:mkpath)
      tools.join("redis-check-aof").tap do |checker|
        checker.write "#!/bin/sh\nexit 0\n"
        File.chmod 0o700, checker
      end

      stdout, stderr, status = Open3.capture3(
        {
          "EXPECTED_INSTALLATION_FINGERPRINT" => manifest.fetch("installation_fingerprint"),
          "EXPECTED_ENVIRONMENT" => "test",
          "BACKUP_AUTHENTICATION_KEY" => AUTHENTICATION_KEY,
          "PATH" => "#{tools}:#{ENV.fetch('PATH')}"
        },
        RbConfig.ruby,
        Rails.root.join("script/admin/verify-backup").to_s,
        generation.to_s
      )

      assert status.success?, stderr
      assert_equal "verified", JSON.parse(stdout).fetch("status")

      original_database = generation.join(manifest.dig("database", "path"))
      alternate_database = generation.join("verified.sqlite3")
      FileUtils.copy_file original_database, alternate_database
      manifest.fetch("database")["path"] = alternate_database.basename.to_s
      generation.join("manifest.json").write(JSON.pretty_generate(manifest))

      error = assert_raises(RuntimeError) do
        BackupVerifier.verify(
          generation_path: generation,
          expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
          expected_environment: "test"
        )
      end
      assert_match "authentication failed", error.message
    end
  end

  test "verification requires the complete database sidecar contract" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))
      payload = manifest.except("authentication")
      payload.fetch("source_state").delete("database_sidecars")
      generation.join("manifest.json").write JSON.pretty_generate(
        CampfireBackup::Authentication.sign_manifest(
          payload, key: Base64.strict_decode64(AUTHENTICATION_KEY)
        )
      )

      error = assert_raises(RuntimeError) do
        BackupVerifier.verify(
          generation_path: generation,
          expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
          expected_environment: "test"
        )
      end

      assert_match "source-state inventory is invalid", error.message
    end
  end

  test "requires an explicit assertion that the source is quiesced" do
    with_storage do |storage, backups|
      error = assert_raises(RuntimeError) do
        Backup.create(
          destination_directory: backups, storage_directory: storage,
          database_relative_path: "db/test.sqlite3"
        )
      end

      assert_match "CAMPFIRE IS STOPPED", error.message
      assert_empty backups.children
    end
  end

  test "installation identity remains stable when the join code changes" do
    with_storage do |storage, backups|
      first = backup_manifest(storage, backups)
      accounts(:signal).update!(join_code: "a-new-join-code")
      second = backup_manifest(storage, backups)

      assert_equal first.fetch("installation_fingerprint"), second.fetch("installation_fingerprint")
    end
  end

  test "installation identity cannot be changed" do
    account = accounts(:signal)

    assert_not account.update(installation_identifier: SecureRandom.uuid)
    assert_includes account.errors[:installation_identifier], "cannot be changed"
  end

  test "installation marker remains readable without containing authentication key material" do
    with_storage do |storage, backups|
      marker = storage.join(CampfireBackup::InstallationIdentity::FILENAME)
      marker.write "#{accounts(:signal).installation_identifier}\n"
      File.chmod 0o600, marker

      manifest = backup_manifest(storage, backups)
      copied_marker = backups.join(manifest.fetch("backup_id"), "payload", marker.basename)

      assert_equal 0o644, marker.stat.mode & 0o777
      assert_equal 0o640, copied_marker.stat.mode & 0o777
      assert_equal accounts(:signal).installation_identifier, copied_marker.read.strip
      refute_includes copied_marker.read, AUTHENTICATION_KEY

      restored_storage = storage.dirname.join("restored-storage")
      capture_io do
        BackupInstaller.install(
          generation_path: backups.join(manifest.fetch("backup_id")),
          storage_directory: restored_storage,
          expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
          expected_environment: "test", runtime_uid: Process.euid, runtime_gid: Process.egid
        )
      end
      restored_marker = restored_storage.join(CampfireBackup::InstallationIdentity::FILENAME)
      assert_equal 0o644, restored_marker.stat.mode & 0o777
      assert_equal accounts(:signal).installation_identifier, restored_marker.read.strip
      assert_not restored_storage.join(CampfireBackup::RecoveryMarkers::RESTORE_FILENAME).exist?
    end
  end

  test "refuses a linked installation marker without changing its target" do
    with_storage do |storage, backups|
      target = storage.dirname.join("outside-identifier").tap do |path|
        path.write "#{accounts(:signal).installation_identifier}\n"
        File.chmod 0o600, path
      end
      File.symlink target, storage.join(CampfireBackup::InstallationIdentity::FILENAME)

      error = assert_raises(RuntimeError) { backup_manifest(storage, backups) }

      assert_match "not an independent regular file", error.message
      assert_equal accounts(:signal).installation_identifier, target.read.strip
      assert_equal 0o600, target.stat.mode & 0o777
    end
  end

  test "refuses to publish when a database blob is missing from the generation" do
    data = "required uploaded bytes"
    ActiveStorage::Blob.create!(
      key: "abcdef1234567890", filename: "required.txt", service_name: "local",
      byte_size: data.bytesize, checksum: Base64.strict_encode64(Digest::MD5.digest(data)),
      content_type: "text/plain"
    )

    with_storage do |storage, backups|
      error = assert_raises(RuntimeError) do
        Backup.create(
          destination_directory: backups, storage_directory: storage,
          confirmation: Backup::QUIESCENCE_CONFIRMATION,
          database_relative_path: "db/test.sqlite3"
        )
      end

      assert_match "missing uploaded file", error.message
      assert_not backups.join("latest").exist?
    end
  end

  test "creating a backup never removes an older recovery generation" do
    with_storage do |storage, backups|
      Time.stubs(:current).returns(Time.utc(2026, 7, 31, 12, 0, 0))

      first = backup_manifest(storage, backups)
      second = backup_manifest(storage, backups)

      assert backups.join(first.fetch("backup_id")).exist?
      assert backups.join(second.fetch("backup_id")).exist?
      assert_equal second.fetch("backup_id"), backups.join("latest").realpath.basename.to_s
    end
  end

  test "rejects a valid database rewrite even when every unkeyed checksum is recomputed" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))
      database_path = generation.join(manifest.dig("database", "path"))
      database = SQLite3::Database.new(database_path.to_s)
      database.execute("UPDATE users SET password_digest = 'attacker-controlled' WHERE id = (SELECT MIN(id) FROM users)")
      database.close
      manifest.fetch("database")["bytes"] = database_path.size
      manifest.fetch("database")["sha256"] = Digest::SHA256.file(database_path).hexdigest
      manifest.fetch("source_state").fetch("database")["bytes"] = database_path.size
      manifest.fetch("source_state").fetch("database")["sha256"] = Digest::SHA256.file(database_path).hexdigest
      generation.join("manifest.json").write(JSON.pretty_generate(manifest))

      error = assert_raises(RuntimeError) do
        BackupVerifier.verify(
          generation_path: generation,
          expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
          expected_environment: "test"
        )
      end

      assert_match "authentication failed", error.message
    end
  end

  test "rejects a signed database that is missing part of the application schema" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))
      database_path = generation.join(manifest.dig("database", "path"))
      database = SQLite3::Database.new(database_path.to_s)
      database.execute("DROP TABLE searches")
      database.close
      manifest.fetch("database")["bytes"] = database_path.size
      manifest.fetch("database")["sha256"] = Digest::SHA256.file(database_path).hexdigest
      manifest.fetch("source_state").fetch("database")["bytes"] = database_path.size
      manifest.fetch("source_state").fetch("database")["sha256"] = Digest::SHA256.file(database_path).hexdigest
      payload = manifest.except("authentication")
      signed = CampfireBackup::Authentication.sign_manifest(
        payload, key: CampfireBackup::Authentication.key_from_env
      )
      generation.join("manifest.json").write(JSON.pretty_generate(signed))

      error = assert_raises(RuntimeError) do
        BackupVerifier.verify(
          generation_path: generation,
          expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
          expected_environment: "test"
        )
      end

      assert_match "schema contract", error.message
    end
  end

  test "schema verification preserves case-sensitive SQL literals" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))
      database_path = generation.join(manifest.dig("database", "path"))
      database = SQLite3::Database.new(database_path.to_s)
      database.execute("PRAGMA writable_schema = ON")
      database.execute <<~SQL
        UPDATE sqlite_schema
        SET sql = replace(sql, '''authenticate''', '''AUTHENTICATE''')
        WHERE type = 'table' AND name = 'oidc_flows'
      SQL
      database.execute("PRAGMA writable_schema = OFF")
      database.close
      manifest.fetch("database")["bytes"] = database_path.size
      manifest.fetch("database")["sha256"] = Digest::SHA256.file(database_path).hexdigest
      manifest.fetch("source_state").fetch("database")["bytes"] = database_path.size
      manifest.fetch("source_state").fetch("database")["sha256"] = Digest::SHA256.file(database_path).hexdigest
      signed = CampfireBackup::Authentication.sign_manifest(
        manifest.except("authentication"), key: CampfireBackup::Authentication.key_from_env
      )
      generation.join("manifest.json").write(JSON.pretty_generate(signed))

      error = assert_raises(RuntimeError) do
        BackupVerifier.verify(
          generation_path: generation,
          expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
          expected_environment: "test"
        )
      end

      assert_match "schema contract", error.message
    end
  end

  test "archives, authenticates, extracts, and installs exact bytes into an empty volume" do
    with_storage do |storage, backups|
      stored_file = storage.join("files", "room", "history.txt")
      stored_file.dirname.mkpath
      stored_file.write "restored history"
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))

      Dir.mktmpdir("campfire-archive") do |directory|
        archive_directory = Pathname(directory).join("archives")
        archive = nil
        capture_io do
          archive = BackupArchiver.archive(
            generation_path: generation,
            destination_directory: archive_directory,
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", encryption_keyring: encryption_keyring
          )
        end
        extraction_root = Pathname(directory).join("extracted")
        extracted = nil
        capture_io do
          extracted = BackupExtractor.extract(
            archive_path: archive,
            destination_directory: extraction_root,
            backup_id: manifest.fetch("backup_id"),
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", encryption_keyring: encryption_keyring
          )
        end
        restored_storage = Pathname(directory).join("restored-storage")
        restored_storage.join("db").mkpath
        restored_storage.join("files").mkpath
        restored_storage.join(".keep").write ""

        capture_io do
          BackupInstaller.install(
            generation_path: extracted,
            storage_directory: restored_storage,
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", runtime_uid: Process.euid, runtime_gid: Process.egid
          )
        end

        assert_equal "restored history", restored_storage.join("files/room/history.txt").read
        assert_equal manifest.dig("database", "sha256"),
          Digest::SHA256.file(restored_storage.join("db/test.sqlite3")).hexdigest
      end
    end
  end

  test "rejects altered archive bytes before parsing or writing them" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))

      Dir.mktmpdir("campfire-archive") do |directory|
        archive = nil
        capture_io do
          archive = BackupArchiver.archive(
            generation_path: generation,
            destination_directory: directory,
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", encryption_keyring: encryption_keyring
          )
        end
        File.open(archive, "ab") { _1.write("tampered") }
        BackupExtractor.expects(:inspect_archive).never
        destination = Pathname(directory).join("restore")

        assert_raises(RuntimeError) do
          BackupExtractor.extract(
            archive_path: archive,
            destination_directory: destination,
            backup_id: manifest.fetch("backup_id"),
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", encryption_keyring: encryption_keyring
          )
        end
        assert_empty destination.children.reject {
          _1.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
        }
      end
    end
  end

  test "refuses to archive unexpected generation symlinks" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))

      Dir.mktmpdir("campfire-archive-link") do |directory|
        secret = Pathname(directory).join("secret").tap { _1.write "must not be archived" }
        generation.join("leak").make_symlink(secret)
        archive_directory = Pathname(directory).join("archives")

        assert_raises(RuntimeError) do
          capture_io do
            BackupArchiver.archive(
              generation_path: generation,
              destination_directory: archive_directory,
              expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
              expected_environment: "test", encryption_keyring: encryption_keyring
            )
          end
        end
        assert_empty archive_directory.children.reject {
          _1.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
        }
      end
    end
  end

  test "refuses to publish an archive changed after source verification" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))

      Dir.mktmpdir("campfire-archive-source-change") do |directory|
        archive_directory = Pathname(directory).join("archives")
        write_archive = BackupArchiver.method(:write_archive)
        BackupArchiver.stubs(:write_archive).with do |path, source|
          source.join("unmanifested.txt").write "created after source verification"
          write_archive.call(path, source)
          true
        end.returns(nil)

        error = assert_raises(RuntimeError) do
          BackupArchiver.archive(
            generation_path: generation,
            destination_directory: archive_directory,
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", encryption_keyring: encryption_keyring
          )
        end

        assert_match "unexpected or missing entries", error.message
        assert_empty archive_directory.children.reject {
          _1.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
        }
      end
    end
  end

  test "creates and verifies a recovery generation before the identity migration mutates the database" do
    with_database_at(20251212154340) do |connection|
      connection.execute <<~SQL
        INSERT INTO accounts (id, name, join_code, singleton_guard, created_at, updated_at)
        VALUES (1, 'Pre-upgrade Campfire', 'pre-upgrade', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      insert_preupgrade_duplicate_messages(connection)

      with_storage do |storage, backups|
        marker = storage.join(CampfireBackup::InstallationIdentity::FILENAME)
        with_env "CAMPFIRE_INSTALLATION_IDENTIFIER_PATH" => marker.to_s do
          manifest = backup_manifest(storage, backups, legacy: true)

          assert_equal 20251212154340, manifest.fetch("schema_version")
          assert marker.file?
          assert_not ActiveRecord::Base.connection.column_exists?(:accounts, :installation_identifier)
          capture_io do
            assert BackupVerifier.verify(
              generation_path: backups.join(manifest.fetch("backup_id")),
              expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
              expected_environment: "test"
            )
          end

          ActiveRecord::Base.connection_pool.migration_context.up
          identifier = ActiveRecord::Base.connection.select_value("SELECT installation_identifier FROM accounts")
          assert_equal marker.read.strip, identifier
          assert_equal 2, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM messages").to_i
          assert_equal 2,
            ActiveRecord::Base.connection.select_value("SELECT COUNT(DISTINCT client_message_id) FROM messages").to_i
          assert_equal 2, ActiveRecord::Base.connection.select_value("SELECT message_id FROM boosts WHERE id = 1").to_i
        end
      end
    end
  end

  test "rejects a validator that changes copied payload bytes" do
    with_storage do |storage, backups|
      redis_file = storage.join("redis", "appendonly.aof")
      redis_file.dirname.mkpath
      redis_file.write "before validation"
      CampfireBackup::RedisValidator.stubs(:validate!).with do |payload|
        Pathname(payload).join("redis", "appendonly.aof").write "after validation"
        true
      end.returns(nil)

      error = assert_raises(RuntimeError) { backup_manifest(storage, backups) }
      assert_match "source state changed", error.message
    end
  end

  test "source state remains stable when checkpoint sidecars disappear on close" do
    Dir.mktmpdir("campfire-source-sidecars") do |directory|
      storage = Pathname(directory)
      database_path = storage.join("db/test.sqlite3")
      database_path.dirname.mkpath
      identifier = "1" * 32
      storage.join(CampfireBackup::InstallationIdentity::FILENAME).write "#{identifier}\n"
      database = SQLite3::Database.new(database_path.to_s)
      database.execute("PRAGMA journal_mode = WAL")
      database.execute("CREATE TABLE schema_migrations (version varchar NOT NULL PRIMARY KEY)")
      database.execute("INSERT INTO schema_migrations (version) VALUES ('1')")
      assert_equal [ 0, 0, 0 ], database.get_first_row("PRAGMA wal_checkpoint(TRUNCATE)")

      before = CampfireBackup::SourceStateInventory.capture(
        database:, database_path:, storage_directory: storage,
        environment: "test", backup_id: "backup", installation_identifier: identifier,
        schema_version: 1
      )
      database.close
      database = nil
      after = CampfireBackup::SourceStateInventory.capture(
        database: database_path, database_path:, storage_directory: storage,
        environment: "test", backup_id: "backup", installation_identifier: identifier,
        schema_version: 1
      )

      assert_equal before, after
      assert_equal %w[ absent absent-or-regular-transient absent-or-empty ],
        after.fetch("database_sidecars").pluck("required_state")
    ensure
      database&.close
    end
  end

  test "source state rejects uncheckpointed WAL bytes" do
    Dir.mktmpdir("campfire-source-wal") do |directory|
      storage = Pathname(directory)
      database_path = storage.join("db/test.sqlite3")
      database_path.dirname.mkpath
      identifier = "1" * 32
      database = SQLite3::Database.new(database_path.to_s)
      database.execute("PRAGMA journal_mode = WAL")
      database.execute("CREATE TABLE schema_migrations (version varchar NOT NULL PRIMARY KEY)")

      error = assert_raises(RuntimeError) do
        CampfireBackup::SourceStateInventory.capture(
          database:, database_path:, storage_directory: storage,
          environment: "test", backup_id: "backup", installation_identifier: identifier,
          schema_version: 1
        )
      end

      assert_match "WAL contains uncheckpointed bytes", error.message
    ensure
      database&.close
    end
  end

  test "removes owned restore bytes but preserves interruption evidence when validation fails" do
    with_storage do |storage, backups|
      redis_file = storage.join("redis", "appendonly.aof")
      redis_file.dirname.mkpath
      redis_file.write "authenticated redis"
      CampfireBackup::RedisValidator.stubs(:validate!)
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))

      Dir.mktmpdir("campfire-corrupt-restore") do |directory|
        restored_storage = Pathname(directory).join("storage")
        CampfireBackup::RedisValidator.stubs(:validate!).with do |path|
          if Pathname(path).realpath == restored_storage.realpath
            restored_storage.join("redis", "appendonly.aof").write "changed after copy"
          end
          true
        end.returns(nil)

        assert_raises(RuntimeError) do
          capture_io do
            BackupInstaller.install(
              generation_path: generation,
              storage_directory: restored_storage,
              expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
              expected_environment: "test", runtime_uid: Process.euid, runtime_gid: Process.egid
            )
          end
        end
        remaining = restored_storage.children.reject {
          _1.basename.to_s == CampfireBackup::OperationLock::SHARED_FILENAME
        }
        assert_equal [ CampfireBackup::RecoveryMarkers::RESTORE_FILENAME ],
          remaining.map { _1.basename.to_s }
      end
    end
  end

  test "final install validation rejects an unexpected empty directory" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))

      Dir.mktmpdir("campfire-restore-inventory") do |directory|
        restored_storage = Pathname(directory).join("storage")

        error = assert_raises(RuntimeError) do
          BackupInstaller.install(
            generation_path: generation, storage_directory: restored_storage,
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", runtime_uid: Process.euid, runtime_gid: Process.egid,
            fault_after: ->(step) {
              restored_storage.join("unexpected-empty").mkpath if step == "synced"
            }
          )
        end

        assert_match "unexpected or missing entries", error.message
      end
    end
  end

  test "final install validation never follows a file replaced by a symlink" do
    with_storage do |storage, backups|
      stored_file = storage.join("files/room/history.txt")
      stored_file.dirname.mkpath
      stored_file.write "authenticated history"
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))

      Dir.mktmpdir("campfire-restore-symlink-race") do |directory|
        root = Pathname(directory)
        restored_storage = root.join("storage")
        outside = root.join("outside-secret").tap { _1.write "authenticated history" }
        replaced = false
        CampfireBackup::RedisValidator.stubs(:validate!).with do |candidate|
          if Pathname(candidate).realpath == restored_storage.realpath && !replaced
            path = restored_storage.join("files/room/history.txt")
            path.unlink
            path.make_symlink outside
            replaced = true
          end
          true
        end.returns(true)

        error = assert_raises(RuntimeError) do
          BackupInstaller.install(
            generation_path: generation, storage_directory: restored_storage,
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", runtime_uid: Process.euid, runtime_gid: Process.egid
          )
        end

        assert replaced
        assert_match "not an independent regular file", error.message
        assert_equal "authenticated history", outside.read
      end
    end
  end

  test "ownership handoff cannot chown or chmod an external target through a raced symlink" do
    with_storage do |storage, backups|
      manifest = backup_manifest(storage, backups)
      generation = backups.join(manifest.fetch("backup_id"))

      Dir.mktmpdir("campfire-restore-ownership-race") do |directory|
        root = Pathname(directory)
        restored_storage = root.join("storage")
        displaced_marker = root.join("displaced-installation-identifier")
        outside = root.join("outside-sensitive-file").tap do |path|
          path.write "external"
          File.chmod 0o640, path
        end
        outside_before = outside.lstat
        original_setter = BackupInstaller.method(:set_descriptor_metadata!)
        raced = false

        BackupInstaller.define_singleton_method(:set_descriptor_metadata!) do |file, path, uid:, gid:, mode:|
          if !raced && Pathname(path).basename.to_s == CampfireBackup::InstallationIdentity::FILENAME
            canonical_marker = Pathname(path)
            File.rename canonical_marker, displaced_marker
            File.symlink outside, canonical_marker
            raced = true
          end
          original_setter.call(file, path, uid:, gid:, mode:)
        end
        BackupInstaller.singleton_class.send(:private, :set_descriptor_metadata!)

        error = assert_raises(RuntimeError) do
          BackupInstaller.install(
            generation_path: generation, storage_directory: restored_storage,
            expected_installation_fingerprint: manifest.fetch("installation_fingerprint"),
            expected_environment: "test", runtime_uid: Process.euid, runtime_gid: Process.egid
          )
        end

        assert raced
        assert_match "changed during ownership handoff", error.message
        outside_after = outside.lstat
        assert_equal [ outside_before.uid, outside_before.gid, outside_before.mode & 0o777 ],
          [ outside_after.uid, outside_after.gid, outside_after.mode & 0o777 ]
        assert_equal 0o644, displaced_marker.lstat.mode & 0o777
      ensure
        BackupInstaller.define_singleton_method(:set_descriptor_metadata!) do |file, path, uid:, gid:, mode:|
          original_setter.call(file, path, uid:, gid:, mode:)
        end
        BackupInstaller.singleton_class.send(:private, :set_descriptor_metadata!)
      end
    end
  end

  test "does not report a backup when directory durability is unsupported" do
    with_storage do |storage, backups|
      Backup.stubs(:flush_directory).raises(Errno::ENOTSUP)

      assert_raises(Errno::ENOTSUP) { backup_manifest(storage, backups) }
      assert_not backups.join("latest").exist?
    end
  end

  test "current storage requires clean shutdown proof with no legacy override" do
    with_storage do |storage, backups|
      CampfireBackup::RecoveryMarkers.invalidate_clean_shutdown! storage

      error = assert_raises(RuntimeError) do
        Backup.create(
          destination_directory: backups, storage_directory: storage,
          confirmation: Backup::QUIESCENCE_CONFIRMATION,
          legacy_confirmation: Backup::LEGACY_QUIESCENCE_CONFIRMATION,
          legacy_exit_code: "0", database_relative_path: "db/test.sqlite3"
        )
      end

      assert_match "clean-shutdown proof is missing", error.message
      assert_empty backups.children
    end
  end

  test "legacy storage requires its distinct clean-exit confirmation" do
    with_database_at(20251212154340) do
      with_storage do |storage, _backups|
        error = assert_raises(RuntimeError) do
          Backup.send(
            :verify_shutdown_evidence!, storage,
            legacy_confirmation: Backup::LEGACY_QUIESCENCE_CONFIRMATION,
            legacy_exit_code: "137"
          )
        end
        assert_match "source container is stopped with ExitCode 0", error.message

        assert_nil Backup.send(
          :verify_shutdown_evidence!, storage,
          legacy_confirmation: Backup::LEGACY_QUIESCENCE_CONFIRMATION,
          legacy_exit_code: "0"
        )
      end
    end
  end

  test "preserves unauthenticated stale backup staging instead of deleting it" do
    with_storage do |storage, backups|
      staging = backups.join(".20260731T120000Z-0123456789abcdef.tmp").tap(&:mkpath)
      unknown = staging.join("unknown").tap { _1.write "preserve" }

      error = assert_raises(RuntimeError) { backup_manifest(storage, backups) }

      assert_match "Incomplete backup staging was preserved", error.message
      assert_equal "preserve", unknown.read
    end
  end

  test "refuses to overwrite a non-symlink latest path" do
    with_storage do |storage, backups|
      latest = backups.join("latest").tap { _1.write "unrelated" }

      error = assert_raises(RuntimeError) { backup_manifest(storage, backups) }

      assert_match "latest path is not a symbolic link", error.message
      assert_equal "unrelated", latest.read
      assert_not storage.join(CampfireBackup::InstallationIdentity::FILENAME).exist?
    end
  end

  test "refuses a hard-linked backup destination lock without modifying its peer" do
    with_storage do |storage, backups|
      outside = storage.dirname.join("outside-lock").tap { _1.write "preserve" }
      File.link outside, backups.join(".backup.lock")

      error = assert_raises(RuntimeError) { backup_manifest(storage, backups) }

      assert_match "not an independent regular file", error.message
      assert_equal "preserve", outside.read
    end
  end

  test "generation permission handoff cannot follow a raced symlink" do
    Dir.mktmpdir("campfire-generation-permission-race") do |directory|
      root = Pathname(directory)
      generation = root.join("generation").tap(&:mkpath)
      victim = generation.join("victim").tap { _1.write "generation bytes" }
      displaced = root.join("displaced")
      outside = root.join("outside").tap do |path|
        path.write "outside bytes"
        File.chmod 0o666, path
      end
      outside_before = outside.lstat
      original_open = File.method(:open)
      raced = false

      File.define_singleton_method(:open) do |path, *arguments, **options, &block|
        if !raced && Pathname(path) == victim && arguments.first.is_a?(Integer)
          File.rename victim, displaced
          File.symlink outside, victim
          raced = true
        end
        original_open.call(path, *arguments, **options, &block)
      end

      error = assert_raises(RuntimeError) do
        Backup.send(:make_generation_group_readable!, generation)
      end

      assert raced
      assert_match "changed during permission handoff", error.message
      outside_after = outside.lstat
      assert_equal [ outside_before.gid, outside_before.mode & 0o777 ],
        [ outside_after.gid, outside_after.mode & 0o777 ]
    ensure
      File.define_singleton_method(:open) do |path, *arguments, **options, &block|
        original_open.call(path, *arguments, **options, &block)
      end if original_open
    end
  end

  test "generation permission handoff cannot modify a hard-linked peer" do
    Dir.mktmpdir("campfire-generation-hardlink") do |directory|
      root = Pathname(directory)
      generation = root.join("generation").tap(&:mkpath)
      outside = root.join("outside").tap do |path|
        path.write "outside bytes"
        File.chmod 0o600, path
      end
      File.link outside, generation.join("linked-file")
      before = outside.stat

      error = assert_raises(RuntimeError) do
        Backup.send(:make_generation_group_readable!, generation)
      end

      assert_match "changed during permission handoff", error.message
      after = outside.stat
      assert_equal [ before.gid, before.mode & 0o777 ], [ after.gid, after.mode & 0o777 ]
      assert_equal 2, after.nlink
    end
  end

  test "generation permission handoff cannot modify a peer linked during copying" do
    Dir.mktmpdir("campfire-generation-hardlink-race") do |directory|
      root = Pathname(directory)
      generation = root.join("generation").tap(&:mkpath)
      victim = generation.join("victim").tap do |path|
        path.write "generation bytes"
        File.chmod 0o600, path
      end
      outside = root.join("outside")
      original_copy = IO.method(:copy_stream)
      raced = false
      IO.define_singleton_method(:copy_stream) do |source, destination, *arguments|
        original_copy.call(source, destination, *arguments).tap do
          if !raced && Pathname(source.path) == victim
            File.link victim, outside
            raced = true
          end
        end
      end

      error = assert_raises(RuntimeError) do
        Backup.send(:make_generation_group_readable!, generation)
      end

      assert raced
      assert_match "changed during permission handoff", error.message
      assert_equal "generation bytes", outside.read
      assert_equal 0o600, outside.stat.mode & 0o777
      assert_equal 2, outside.stat.nlink
    ensure
      IO.define_singleton_method(:copy_stream) do |source, destination, *arguments|
        original_copy.call(source, destination, *arguments)
      end if original_copy
    end
  end

  test "generation permission handoff fails closed when the umask removes final permissions" do
    Dir.mktmpdir("campfire-generation-umask") do |directory|
      generation = Pathname(directory).join("generation").tap(&:mkpath)
      victim = generation.join("victim").tap do |path|
        path.write "generation bytes"
        File.chmod 0o600, path
      end
      previous_umask = File.umask(0o077)

      error = assert_raises(RuntimeError) do
        Backup.send(:make_generation_group_readable!, generation)
      end

      assert_match "permissions could not be created safely", error.message
      assert_equal "generation bytes", victim.read
      assert_equal 0o600, victim.stat.mode & 0o777
      assert_empty generation.children.select { _1.basename.to_s.include?(".permissions-") }
    ensure
      File.umask(previous_umask) if previous_umask
    end
  end

  private
    def with_storage
      Dir.mktmpdir("campfire-backup") do |directory|
        storage = Pathname(directory).join("storage").tap(&:mkpath)
        storage.join("redis").tap(&:mkpath).join("appendonly.aof").write("")
        CampfireBackup::RecoveryMarkers.publish_clean_shutdown!(
          storage, boot_id: CampfireBackup::RecoveryMarkers.new_boot_id
        )
        backups = storage.join("backups").tap(&:mkpath)
        yield storage, backups
      end
    end

    def with_database_at(version)
      original_config = ActiveRecord::Base.connection_db_config
      migration_verbosity = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      Dir.mktmpdir("campfire-pre-upgrade") do |directory|
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3", database: File.join(directory, "pre-upgrade.sqlite3"),
          default_transaction_mode: "immediate"
        )
        ActiveRecord::Base.connection_pool.migration_context.up(version)
        yield ActiveRecord::Base.connection
      end
    ensure
      ActiveRecord::Migration.verbose = migration_verbosity
      ActiveRecord::Base.establish_connection(original_config)
    end

    def insert_preupgrade_duplicate_messages(connection)
      connection.execute <<~SQL
        INSERT INTO users
          (id, name, email_address, password_digest, role, status, created_at, updated_at)
        VALUES
          (1, 'Legacy User', 'legacy@example.com', 'digest', 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO rooms
          (id, name, type, creator_id, created_at, updated_at)
        VALUES
          (1, 'Legacy Room', 'Room::Open', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO messages
          (id, room_id, creator_id, client_message_id, created_at, updated_at)
        VALUES
          (1, 1, 1, 'duplicate-message', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
          (2, 1, 1, 'duplicate-message', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      connection.execute <<~SQL
        INSERT INTO boosts
          (id, message_id, booster_id, content, created_at, updated_at)
        VALUES
          (1, 2, 1, '+1', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end


    def backup_manifest(storage, backups, legacy: false)
      legacy_evidence = if legacy
        {
          legacy_confirmation: Backup::LEGACY_QUIESCENCE_CONFIRMATION,
          legacy_exit_code: "0"
        }
      else
        {}
      end
      output = capture_io do
        Backup.create(
          destination_directory: backups, storage_directory: storage,
          confirmation: Backup::QUIESCENCE_CONFIRMATION,
          database_relative_path: "db/test.sqlite3", **legacy_evidence
        )
      end.first.then { JSON.parse(_1) }
      JSON.parse(Pathname(output.fetch("path")).join("manifest.json").read)
    end


    def with_env(values)
      previous = values.to_h { |key, _| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end

    def encryption_keyring
      CampfireBackup::BackupEncryption::Keyring.new(
        active_id: "backup-test", active_key: ENCRYPTION_KEY
      )
    end
end
