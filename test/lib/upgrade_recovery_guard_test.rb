require "test_helper"
require "tmpdir"

load Rails.root.join("bin/boot") unless defined?(UpgradeRecoveryGuard)
load Rails.root.join("script/admin/archive-backup") unless defined?(BackupArchiver)

class UpgradeRecoveryGuardTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  LEGACY_VERSION = 20251212154340
  REVISION = "a" * 40
  KEY = "upgrade-recovery-test-key".ljust(32, "!")
  ENCRYPTION_KEY = "upgrade-recovery-encryption-key".ljust(32, "!")
  ENCRYPTION_KEY_ID = "upgrade-recovery-test"
  IDENTIFIER = "1" * 32
  FINGERPRINT = Digest::SHA256.hexdigest(IDENTIFIER)
  BACKUP_ID = "20260731T120000Z-0123456789abcdef"
  NOW = Time.utc(2026, 7, 31, 12, 0, 0)

  setup do
    BackupVerifier.stubs(:verify).returns(true)
  end

  test "fresh and current databases start without a receipt" do
    with_paths(create_database: false) do |storage, database, _archive, _authentication|
      assert_equal :fresh, guard(storage, database).verify_before_prepare!
    end

    with_paths do |storage, database, _archive, _authentication|
      insert_schema_version database, UpgradeRecoveryGuard::GATED_MIGRATION
      assert_equal :current, guard(storage, database).verify_before_prepare!
    end
  end

  test "legacy database without recovery evidence is blocked without mutation" do
    with_paths do |storage, database, _archive, _authentication|
      before = schema_versions(database)

      error = assert_raises(RuntimeError) { guard(storage, database).verify_before_prepare! }

      assert_match "requires authenticated recovery evidence", error.message
      assert_equal before, schema_versions(database)
    end
  end

  test "data in any durable table prevents fresh database classification" do
    prepare_database = lambda do |database|
      UpgradeRecoveryGuard::FRESHNESS_TABLES.each do |table|
        database.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY)")
      end
      database.execute("CREATE TABLE memberships (id INTEGER PRIMARY KEY, connections INTEGER)")
      database.execute("INSERT INTO memberships (connections) VALUES (3)")
    end

    with_paths(prepare_database:) do |storage, database, _archive, _authentication|
      error = assert_raises(RuntimeError) { guard(storage, database).verify_before_prepare! }

      assert_match "requires authenticated recovery evidence", error.message
    end
  end

  test "regular tables sharing a virtual-table prefix remain durable" do
    prepare_database = lambda do |database|
      UpgradeRecoveryGuard::FRESHNESS_TABLES.each do |table|
        database.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY)")
      end
      database.execute("CREATE VIRTUAL TABLE message_search_index USING fts5(body)")
      database.execute("CREATE TABLE message_search_index_audit (id INTEGER PRIMARY KEY)")
      database.execute("INSERT INTO message_search_index_audit DEFAULT VALUES")
    end

    with_paths(prepare_database:) do |storage, database, _archive, _authentication|
      error = assert_raises(RuntimeError) { guard(storage, database).verify_before_prepare! }

      assert_match "requires authenticated recovery evidence", error.message
    end
  end

  test "shadow tables in an attached schema cannot hide main database rows" do
    with_paths do |storage, database, _archive, _authentication|
      sqlite = SQLite3::Database.new(database.to_s)
      UpgradeRecoveryGuard::FRESHNESS_TABLES.each do |table|
        sqlite.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY)")
      end
      sqlite.execute("CREATE TABLE external_fts_content (id INTEGER PRIMARY KEY)")
      sqlite.execute("INSERT INTO external_fts_content DEFAULT VALUES")
      sqlite.execute("ATTACH DATABASE ':memory:' AS auxiliary")
      sqlite.execute("CREATE VIRTUAL TABLE auxiliary.external_fts USING fts5(body)")
      connection = Struct.new(:raw_connection).new(sqlite)

      assert_not guard(storage, database).send(:fresh_database?, connection:)
    ensure
      sqlite&.close
    end
  end

  test "upgrade authorization rejects unattached legacy blobs without deleting them" do
    prepare_database = ->(database) do
      database.execute <<~SQL
        CREATE TABLE active_storage_blobs (
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          key varchar NOT NULL
        )
      SQL
      database.execute <<~SQL
        CREATE TABLE active_storage_attachments (
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          blob_id bigint NOT NULL
        )
      SQL
      database.execute("INSERT INTO active_storage_blobs (key) VALUES ('legacy-orphan')")
    end

    with_paths(prepare_database:) do |storage, database, archive, authentication|
      error = assert_raises(RuntimeError) do
        guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication)
      end

      assert_match "1 unattached blob", error.message
      assert_match "drain or inventory all legacy purge work", error.message
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
      connection = SQLite3::Database.new(database.to_s, readonly: true)
      assert_equal 1, connection.get_first_value("SELECT COUNT(*) FROM active_storage_blobs")
    ensure
      connection&.close
    end
  end

  test "upgrade authorization rejects legacy disk bytes without a blob row" do
    prepare_database = ->(database) do
      database.execute <<~SQL
        CREATE TABLE active_storage_blobs (
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          key varchar NOT NULL
        )
      SQL
      database.execute <<~SQL
        CREATE TABLE active_storage_attachments (
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          blob_id bigint NOT NULL
        )
      SQL
    end
    prepare_storage = ->(storage) do
      path = storage.join("files", "or", "ph", "orphan-file")
      path.dirname.mkpath
      path.write "untracked legacy bytes"
    end

    with_paths(prepare_database:, prepare_storage:) do |storage, database, archive, authentication|
      error = assert_raises(RuntimeError) do
        guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication)
      end

      assert_match "1 untracked file", error.message
      assert_equal "untracked legacy bytes", storage.join("files", "or", "ph", "orphan-file").read
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "upgrade authorization accepts disk bytes for an attached blob and its variant" do
    source_key = "source-key"
    prepare_database = ->(database) do
      database.execute <<~SQL
        CREATE TABLE active_storage_blobs (
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          key varchar NOT NULL
        )
      SQL
      database.execute <<~SQL
        CREATE TABLE active_storage_attachments (
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          blob_id bigint NOT NULL
        )
      SQL
      database.execute("INSERT INTO active_storage_blobs (key) VALUES (?)", source_key)
      database.execute("INSERT INTO active_storage_attachments (blob_id) VALUES (1)")
    end
    prepare_storage = ->(storage) do
      source = storage.join("files", source_key[0, 2], source_key[2, 2], source_key)
      source.dirname.mkpath
      source.write "source bytes"

      variant_key = "variants/#{source_key}/derivative-key"
      variant = storage.join("files", variant_key[0, 2], variant_key[2, 2], variant_key)
      variant.dirname.mkpath
      variant.write "variant bytes"
    end

    with_paths(prepare_database:, prepare_storage:) do |storage, database, archive, authentication|
      capture_io do
        guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication)
      end

      assert storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).file?
    end
  end

  test "valid external archive authorizes only the exact unchanged database and target" do
    with_paths do |storage, database, archive, authentication|
      authorization_guard = guard(storage, database)
      capture_io { authorization_guard.authorize!(archive_path: archive, authentication_path: authentication) }
      receipt = storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).read
      envelope = JSON.parse(receipt)

      assert_equal %w[
        archive_bytes archive_path archive_sha256 authentication authentication_path
        authentication_sha256 backup_id created_at environment expires_at format_version
        installation_fingerprint kind migration source_manifest_sha256 source_schema_version
        source_state_sha256 target_build_identity target_revision
      ], envelope.keys.sort
      assert_equal %w[ algorithm key_id mac ], envelope.fetch("authentication").keys.sort
      assert_not_includes receipt, KEY
      assert_equal :authorized, guard(storage, database).verify_before_prepare!

      wrong_target = guard(storage, database, revision: "b" * 40)
      assert_match "target", assert_raises(RuntimeError) { wrong_target.verify_before_prepare! }.message

      wrong_build = guard(storage, database, build_id: "b" * 64)
      assert_match "target", assert_raises(RuntimeError) { wrong_build.verify_before_prepare! }.message

      connection = SQLite3::Database.new(database.to_s)
      connection.execute("CREATE TABLE changed_after_authorization (id integer)")
      connection.close
      assert_match "complete current stopped source state", assert_raises(RuntimeError) {
        guard(storage, database).verify_before_prepare!
      }.message
    end
  end

  test "released plaintext archive and authentication files remain valid upgrade evidence" do
    with_paths do |storage, database, encrypted, _authentication|
      archive = encrypted.dirname.join("campfire-#{BACKUP_ID}.tar.gz")
      authentication = encrypted.dirname.join("campfire-#{BACKUP_ID}.authentication.json")
      plaintext_stage = encrypted.dirname.join("plaintext-stage").tap(&:mkpath)
      File.chmod 0o700, plaintext_stage
      CampfireBackup::BackupEncryption.with_decrypted_archive(
        encrypted, keyring: encryption_keyring, temporary_directory: plaintext_stage
      ) do |plaintext, statement, _envelope|
        File.open(archive, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |destination|
          IO.copy_stream plaintext, destination
        end
        authentication.write statement
        File.chmod 0o600, authentication
      end

      capture_io do
        guard(storage, database).authorize!(
          archive_path: archive, authentication_path: authentication
        )
      end

      assert storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).file?
      assert_equal :authorized, guard(storage, database).verify_before_prepare!
    end
  end

  test "recovery authorization cannot cross release workflow attempts" do
    with_paths do |storage, database, archive, authentication|
      attributes = { run_id: 123, architecture: "amd64", revision: REVISION }
      first_attempt = CampfireBackup::BuildIdentity.release_identity(
        **attributes, run_attempt: 1
      )
      second_attempt = CampfireBackup::BuildIdentity.release_identity(
        **attributes, run_attempt: 2
      )
      capture_io do
        guard(storage, database, build_id: first_attempt).authorize!(
          archive_path: archive, authentication_path: authentication
        )
      end

      assert_equal :authorized,
        guard(storage, database, build_id: first_attempt).verify_before_prepare!
      error = assert_raises(RuntimeError) do
        guard(storage, database, build_id: second_attempt).verify_before_prepare!
      end

      assert_match "target", error.message
    end
  end

  test "archive from another installation cannot create authorization" do
    with_paths do |storage, database, archive, authentication|
      replace_archive_statement(archive) do |statement|
        statement["installation_fingerprint"] = "2" * 64
        CampfireBackup::Authentication.sign_statement(statement, key: KEY)
      end

      error = assert_raises(RuntimeError) do
        guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication)
      end

      assert_match(/different Campfire installation|does not match the stopped legacy installation/, error.message)
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "stale same-installation same-schema archive cannot create authorization" do
    with_paths do |storage, database, archive, authentication|
      connection = SQLite3::Database.new(database.to_s)
      connection.execute("CREATE TABLE state_created_after_backup (id integer)")
      connection.close

      error = assert_raises(RuntimeError) do
        guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication)
      end

      assert_match "complete current stopped source state", error.message
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "modified archive cannot create authorization" do
    with_paths do |storage, database, archive, authentication|
      archive.open("ab") { _1.write "tampered" }

      error = assert_raises(RuntimeError) do
        guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication)
      end

      assert_match "trailing bytes", error.message
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "stale authorization is rejected without changing the schema" do
    with_paths do |storage, database, archive, authentication|
      capture_io { guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication) }
      before = schema_versions(database)
      stale = guard(storage, database, now: NOW + UpgradeRecoveryGuard::RECEIPT_LIFETIME + 1)

      assert_match "stale", assert_raises(RuntimeError) { stale.verify_before_prepare! }.message
      assert_equal before, schema_versions(database)
    end
  end

  test "archive evidence on the Campfire volume is rejected" do
    with_paths do |storage, database, archive, authentication|
      on_volume_archive = storage.join(archive.basename)
      on_volume_authentication = storage.join(authentication.basename)
      FileUtils.cp archive, on_volume_archive
      FileUtils.cp authentication, on_volume_authentication

      error = assert_raises(RuntimeError) do
        guard(storage, database).authorize!(
          archive_path: on_volume_archive, authentication_path: on_volume_authentication
        )
      end

      assert_match "outside the Campfire volume", error.message
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "archive evidence mounted through an alias of the Campfire source volume is rejected" do
    with_paths do |storage, database, archive, authentication|
      resolver = lambda do |path|
        path = Pathname(path).realpath
        canonical_storage = storage.realpath
        storage_path = path == canonical_storage || path.to_s.start_with?("#{canonical_storage}/")
        CampfireBackup::MountIdentity::Entry.new(
          mount_id: storage_path ? 201 : 202, parent_id: 1, device: "8:1",
          root: "/docker/volumes/campfire/_data",
          mount_point: storage_path ? canonical_storage.to_s : archive.dirname.realpath.to_s,
          filesystem_type: "ext4", source: "/dev/sda1"
        ).freeze
      end

      error = assert_raises(RuntimeError) do
        guard(storage, database, mount_identity_resolver: resolver).authorize!(
          archive_path: archive, authentication_path: authentication
        )
      end

      assert_match "outside the Campfire volume", error.message
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "archive evidence fails closed when mount source identity is unavailable" do
    with_paths do |storage, database, archive, authentication|
      error = assert_raises(RuntimeError) do
        guard(storage, database, mount_identity_resolver: ->(_path) { nil }).authorize!(
          archive_path: archive, authentication_path: authentication
        )
      end

      assert_match "mount identity could not be verified", error.message
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "successful database preparation consumes the receipt" do
    with_paths do |storage, database, archive, authentication|
      capture_io { guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication) }
      boot_guard = guard(storage, database)
      assert_equal :authorized, boot_guard.verify_before_prepare!
      insert_schema_version database, UpgradeRecoveryGuard::GATED_MIGRATION

      boot_guard.complete!

      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "a restart after migration removes a receipt left before completion" do
    with_paths do |storage, database, archive, authentication|
      capture_io { guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication) }
      insert_schema_version database, UpgradeRecoveryGuard::GATED_MIGRATION

      assert_equal :current, guard(storage, database).verify_before_prepare!

      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "the migration hook blocks a populated production target before authorization" do
    with_production_connection do |root, database, build_identity_path, connection|
      before = connection.select_values("SELECT version FROM schema_migrations ORDER BY version")

      error = assert_raises(ActiveRecord::MigrationError) do
        UpgradeRecoveryGuard.verify_migration!(
          connection:, env: { "RAILS_ENV" => "production" }, root:, build_identity_path:
        )
      end

      assert_match "requires authenticated recovery evidence", error.message
      assert_equal before, connection.select_values("SELECT version FROM schema_migrations ORDER BY version")
      assert_equal database, Pathname(connection.pool.db_config.database)
    end
  end

  test "the migration hook rejects a divergent Active Record production target" do
    with_production_connection(connection_relative_path: "storage/db/divergent.sqlite3") do |root, _database, build_identity_path, connection|
      error = assert_raises(ActiveRecord::MigrationError) do
        UpgradeRecoveryGuard.verify_migration!(
          connection:, env: { "RAILS_ENV" => "production" }, root:, build_identity_path:
        )
      end

      assert_match "Active Record production database does not match", error.message
    end
  end

  test "the migration hook cannot bypass production checks by changing Rails environment" do
    with_production_connection do |root, _database, build_identity_path, connection|
      error = assert_raises(ActiveRecord::MigrationError) do
        UpgradeRecoveryGuard.verify_migration!(
          connection:, env: { "RAILS_ENV" => "development" }, root:, build_identity_path:
        )
      end

      assert_match "cannot be migrated outside RAILS_ENV=production", error.message
    end
  end

  test "production migration rejects a symbolic-link database target" do
    original_config = ActiveRecord::Base.connection_db_config
    Dir.mktmpdir("campfire-production-symlink") do |directory|
      root = Pathname(directory)
      target = root.join("outside.sqlite3")
      create_legacy_database target
      expected = root.join("storage/db/production.sqlite3")
      expected.dirname.mkpath
      File.symlink target, expected
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: expected.to_s)

      error = assert_raises(ActiveRecord::MigrationError) do
        UpgradeRecoveryGuard.verify_migration!(
          connection: ActiveRecord::Base.connection,
          env: { "RAILS_ENV" => "production" }, root:,
          build_identity_path: root.join("unused-build-identity.json")
        )
      end

      assert_match "symbolic link", error.message
    end
  ensure
    ActiveRecord::Base.establish_connection original_config if original_config
  end

  test "the guarded migration context validates authorized evidence through the actual adapter transaction" do
    with_paths do |storage, database, archive, authentication|
      capture_io { guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication) }
      root = storage.dirname
      build_identity_path = root.join("campfire-build-identity.json")
      build_identity_path.write JSON.generate(
        format_version: 1, revision: REVISION,
        build_identity: Digest::SHA256.hexdigest("test-build\0#{REVISION}")
      )
      original_config = ActiveRecord::Base.connection_db_config
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: database.to_s)
      connection = ActiveRecord::Base.connection
      environment = {
        "RAILS_ENV" => "production",
        CampfireBackup::Authentication::KEY_ENVIRONMENT_VARIABLE => Base64.strict_encode64(KEY)
      }
      storage_mount = independent_mount_resolver(storage).call(storage)
      recovery_mount = independent_mount_resolver(storage).call(archive)
      CampfireBackup::MountIdentity.stubs(:for_path).returns(
        storage_mount, recovery_mount, storage_mount, recovery_mount
      )

      result = with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
        UpgradeRecoveryGuard.with_migration_operation(connection:, env: environment, root:) do
          UpgradeRecoveryGuard.verify_migration!(
            connection:, env: environment, now: NOW, root:, build_identity_path:
          )
        end
      end

      assert_equal :authorized, result
    ensure
      ActiveRecord::Base.establish_connection original_config if original_config
    end
  end

  test "migration context blocks before the first pending production migration" do
    with_production_connection do |root, database, _build_identity_path, connection|
      Rails.stubs(:root).returns(root)
      CampfireBackup::BuildIdentity.stubs(:read!).returns({
        "format_version" => 1,
        "revision" => REVISION,
        "build_identity" => Digest::SHA256.hexdigest("production-migration-test")
      })
      before_versions = schema_versions(database)
      before_tables = connection.tables.sort

      error = with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
        assert_raises(ActiveRecord::MigrationError) do
          connection.pool.migration_context.up
        end
      end

      assert_match "requires authenticated recovery evidence", error.message
      assert_equal before_versions, schema_versions(database)
      assert_equal before_tables, connection.tables.sort
    end
  end

  test "migration context authorizes before invoking its selection block" do
    with_production_connection do |root, _database, _build_identity_path, connection|
      Rails.stubs(:root).returns(root)
      CampfireBackup::BuildIdentity.stubs(:read!).returns({
        "format_version" => 1,
        "revision" => REVISION,
        "build_identity" => Digest::SHA256.hexdigest("production-migration-test")
      })
      selection_called = false

      error = with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
        assert_raises(ActiveRecord::MigrationError) do
          connection.pool.migration_context.up do
            selection_called = true
            connection.create_table(:migration_selection_side_effect)
            false
          end
        end
      end

      assert_match "requires authenticated recovery evidence", error.message
      assert_not selection_called
      assert_not connection.table_exists?(:migration_selection_side_effect)
    end
  end

  test "migration selection database side effects are always rolled back" do
    connection = ActiveRecord::Base.connection
    table = :migration_selection_side_effect
    migration = Data.define(:version).new(20_260_803_000_000)
    context_class = Class.new do
      attr_reader :migrations, :schema_migration

      def initialize(migrations, schema_migration)
        @migrations = migrations
        @schema_migration = schema_migration
      end

      def up(_target_version = nil)
        migrations.select { |candidate| yield candidate }
      end
    end
    context_class.prepend CampfireBackup::UpgradeRecoveryGuard::MigrationContextGuard
    context = context_class.new([ migration ], connection.pool.schema_migration)
    CampfireBackup::UpgradeRecoveryGuard.stubs(:with_verified_migration).yields

    context.up do
      connection.create_table(table)
      false
    end

    assert_not connection.table_exists?(table)
  ensure
    connection&.drop_table(table, if_exists: true)
  end

  test "production rejects a migration selection block after authorization" do
    connection = ActiveRecord::Base.connection
    migration = Data.define(:version).new(20_260_803_000_000)
    context_class = Class.new do
      attr_reader :migrations, :schema_migration

      def initialize(migrations, schema_migration)
        @migrations = migrations
        @schema_migration = schema_migration
      end

      def up(_target_version = nil)
        migrations.select { |candidate| yield candidate }
      end
    end
    context_class.prepend CampfireBackup::UpgradeRecoveryGuard::MigrationContextGuard
    context = context_class.new([ migration ], connection.pool.schema_migration)
    CampfireBackup::UpgradeRecoveryGuard.expects(:with_verified_migration).yields
    selection_called = false

    error = with_environment("RAILS_ENV" => "production") do
      assert_raises(ActiveRecord::MigrationError) do
        context.up do
          selection_called = true
          false
        end
      end
    end

    assert_match "selection blocks are unsupported", error.message
    assert_not selection_called
  end

  test "production rejects a rollback selection block after authorization" do
    connection = ActiveRecord::Base.connection
    migration = Data.define(:version).new(20_260_803_000_000)
    context_class = Class.new do
      attr_reader :migrations, :schema_migration

      def initialize(migrations, schema_migration)
        @migrations = migrations
        @schema_migration = schema_migration
      end

      def down(_target_version = nil)
        migrations.select { |candidate| yield candidate }
      end
    end
    context_class.prepend CampfireBackup::UpgradeRecoveryGuard::MigrationContextGuard
    context = context_class.new([ migration ], connection.pool.schema_migration)
    CampfireBackup::UpgradeRecoveryGuard.expects(:with_verified_migration).yields
    selection_called = false

    error = with_environment("RAILS_ENV" => "production") do
      assert_raises(ActiveRecord::MigrationError) do
        context.down do
          selection_called = true
          false
        end
      end
    end

    assert_match "selection blocks are unsupported", error.message
    assert_not selection_called
  end

  test "the database tasks capability permits only its migration selection" do
    connection = ActiveRecord::Base.connection
    migration = Data.define(:version)
    selected = migration.new(20_260_803_000_000)
    excluded = migration.new(20_260_803_000_001)
    context_class = Class.new do
      attr_reader :migrations, :schema_migration, :selected_migrations

      def initialize(migrations, schema_migration)
        @migrations = migrations
        @schema_migration = schema_migration
      end

      def migrate(target_version = nil, &selection)
        up(target_version, &selection)
      end

      def up(_target_version = nil)
        @selected_migrations = migrations.select { |candidate| yield candidate }
      end
    end
    context_class.prepend CampfireBackup::UpgradeRecoveryGuard::MigrationContextGuard
    context = context_class.new([ selected, excluded ], connection.pool.schema_migration)
    tasks_class = Class.new do
      def initialize(context, version)
        @context = context
        @version = version
      end

      def migrate
        @context.migrate { |migration| migration.version == @version }
      end
    end
    tasks_class.prepend CampfireBackup::UpgradeRecoveryGuard::DatabaseTasksMigrationGuard
    CampfireBackup::UpgradeRecoveryGuard.expects(:with_verified_migration).yields

    with_environment("RAILS_ENV" => "production") do
      tasks_class.new(context, selected.version).migrate
    end

    assert_equal [ selected ], context.selected_migrations
    assert_not CampfireBackup::UpgradeRecoveryGuard.database_tasks_migration?
    assert_not CampfireBackup::UpgradeRecoveryGuard.trusted_migration_selection?(context)
  end

  test "production migration context contends on the shared storage lock" do
    with_production_connection do |root, _database, _build_identity_path, connection|
      Rails.stubs(:root).returns(root)
      CampfireBackup::BuildIdentity.stubs(:read!).returns({
        "format_version" => 1,
        "revision" => REVISION,
        "build_identity" => Digest::SHA256.hexdigest("production-migration-test")
      })
      shared_path = root.join("storage", CampfireBackup::OperationLock::SHARED_FILENAME)
      File.open(shared_path, File::RDWR | File::CREAT, 0o600) do |shared_file|
        assert shared_file.flock(File::LOCK_EX | File::LOCK_NB)

        error = with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
          assert_raises(RuntimeError) { connection.pool.migration_context.up }
        end

        assert_match "in use by another process", error.message
        rollback_error = with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
          assert_raises(RuntimeError) { connection.pool.migration_context.down(0) }
        end
        assert_match "in use by another process", rollback_error.message
      end
    end
  end

  test "database pathname replacement aborts inside the migration transaction" do
    original_config = ActiveRecord::Base.connection_db_config
    Dir.mktmpdir("campfire-migration-inode") do |directory|
      root = Pathname(directory)
      migrations = root.join("migrations").tap(&:mkpath)
      migrations.join("20260729000000_replace_migration_database_path.rb").write <<~RUBY
        class ReplaceMigrationDatabasePath < ActiveRecord::Migration[8.2]
          def up
            path = Pathname(connection.pool.db_config.database)
            File.rename(path, "\#{path}.opened")
            SQLite3::Database.new(path.to_s).close
            create_table :migration_must_not_commit
          end
        end
      RUBY
      Rails.stubs(:root).returns(root)
      CampfireBackup::BuildIdentity.stubs(:read!).returns({
        "format_version" => 1,
        "revision" => REVISION,
        "build_identity" => Digest::SHA256.hexdigest("production-migration-test")
      })
      database = root.join("storage/db/production.sqlite3")
      database.dirname.mkpath
      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3", database: database.to_s, default_transaction_mode: "immediate"
      )
      connection = ActiveRecord::Base.connection
      connection.execute("PRAGMA user_version")
      pool = connection.pool
      context = ActiveRecord::MigrationContext.new(
        migrations.to_s, pool.schema_migration, pool.internal_metadata
      )

      error = with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
        assert_raises(StandardError) { context.up }
      end

      assert_match "main database file moved", error.message
      assert_not connection.table_exists?(:migration_must_not_commit)
      replacement = SQLite3::Database.new(database.to_s, readonly: true)
      assert_empty replacement.table_info("migration_must_not_commit")
      replacement.close
    end
  ensure
    ActiveRecord::Base.establish_connection original_config if original_config
  end

  test "direct migration context run uses the same production preflight" do
    with_production_connection do |root, database, _build_identity_path, connection|
      Rails.stubs(:root).returns(root)
      CampfireBackup::BuildIdentity.stubs(:read!).returns({
        "format_version" => 1,
        "revision" => REVISION,
        "build_identity" => Digest::SHA256.hexdigest("production-migration-test")
      })
      before = schema_versions(database)

      error = with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
        assert_raises(ActiveRecord::MigrationError) do
          connection.pool.migration_context.run(:up, UpgradeRecoveryGuard::GATED_MIGRATION)
        end
      end

      assert_match "requires authenticated recovery evidence", error.message
      assert_equal before, schema_versions(database)
    end
  end

  test "migration context open blocks before constructing a production migrator" do
    with_production_connection do |root, database, _build_identity_path, connection|
      migrations = root.join("open-migrations").tap(&:mkpath)
      migrations.join("20260729000000_create_open_preflight.rb").write <<~RUBY
        class CreateOpenPreflight < ActiveRecord::Migration[8.2]
          def change
            create_table :open_preflight
          end
        end
      RUBY
      Rails.stubs(:root).returns(root)
      CampfireBackup::BuildIdentity.stubs(:read!).returns({
        "format_version" => 1,
        "revision" => REVISION,
        "build_identity" => Digest::SHA256.hexdigest("production-migration-test")
      })
      pool = connection.pool
      context = ActiveRecord::MigrationContext.new(
        migrations.to_s, pool.schema_migration, pool.internal_metadata
      )

      error = with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
        assert_raises(ActiveRecord::MigrationError) { context.open.migrate }
      end

      assert_match "requires authenticated recovery evidence", error.message
      assert_not connection.table_exists?(:open_preflight)
      assert_equal [ LEGACY_VERSION.to_s ], schema_versions(database)
    end
  end

  test "direct production migrator construction fails closed" do
    with_production_connection do |_root, _database, _build_identity_path, connection|
      pool = connection.pool

      errors = with_environment("RAILS_ENV" => "production") do
        %i[ up down ].map do |direction|
          assert_raises(ActiveRecord::MigrationError) do
            ActiveRecord::Migrator.new(direction, [], pool.schema_migration, pool.internal_metadata)
          end
        end
      end

      errors.each { assert_match "guarded Active Record migration context", _1.message }
    end
  end

  test "production destructive rollback has no implicit upgrade-recovery authorization" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      UpgradeRecoveryGuard.authorize_destructive_rollback!(
        migration: "CreateIdentities", env: { "RAILS_ENV" => "production" }
      )
    end

    assert_match "separately authenticated rollback archive", error.message
    assert_equal :not_production, UpgradeRecoveryGuard.authorize_destructive_rollback!(
      migration: "CreateIdentities", env: { "RAILS_ENV" => "test" }
    )
  end

  test "production preflight spans every pending migration through the gate" do
    original_config = ActiveRecord::Base.connection_db_config
    Dir.mktmpdir("campfire-prepare-preflight") do |directory|
      root = Pathname(directory)
      migrations = root.join("migrations").tap(&:mkpath)
      migrations.join("20260729000000_create_prepare_preflight_first.rb").write <<~RUBY
        class CreatePreparePreflightFirst < ActiveRecord::Migration[8.2]
          def change
            create_table :prepare_preflight_first
          end
        end
      RUBY
      migrations.join("20260730000000_create_prepare_preflight_gate.rb").write <<~RUBY
        class CreatePreparePreflightGate < ActiveRecord::Migration[8.2]
          def up
            CampfireBackup::UpgradeRecoveryGuard.verify_migration!(connection:)
            create_table :prepare_preflight_gate
          end

          def down
            drop_table :prepare_preflight_gate
          end
        end
      RUBY
      Rails.stubs(:root).returns(root)
      CampfireBackup::BuildIdentity.stubs(:read!).returns({
        "format_version" => 1,
        "revision" => REVISION,
        "build_identity" => Digest::SHA256.hexdigest("production-migration-test")
      })
      database = root.join("storage/db/production.sqlite3")
      database.dirname.mkpath
      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3", database: database.to_s, default_transaction_mode: "immediate"
      )
      pool = ActiveRecord::Base.connection_pool
      context = ActiveRecord::MigrationContext.new(
        migrations.to_s, pool.schema_migration, pool.internal_metadata
      )

      with_environment("RAILS_ENV" => "production", "DATABASE_URL" => nil) do
        context.up
      end

      assert ActiveRecord::Base.connection.table_exists?(:prepare_preflight_first)
      assert ActiveRecord::Base.connection.table_exists?(:prepare_preflight_gate)
      assert_nil Thread.current.thread_variable_get(
        CampfireBackup::UpgradeRecoveryGuard::MIGRATION_CONTEXT_TARGETS_KEY
      )
      assert_nil Thread.current.thread_variable_get(
        CampfireBackup::UpgradeRecoveryGuard::MIGRATION_OPERATION_KEY
      )
    end
  ensure
    Thread.current.thread_variable_set(CampfireBackup::UpgradeRecoveryGuard::MIGRATION_CONTEXT_TARGETS_KEY, nil)
    ActiveRecord::Base.establish_connection original_config if original_config
  end

  test "backup target validation uses the actual Active Record production connection" do
    with_production_connection do |root, database, _build_identity_path, connection|
      actual = CampfireBackup::UpgradeRecoveryGuard.verify_backup_target!(
        connection:, storage_directory: root.join("storage"),
        env: { "RAILS_ENV" => "production" }, root:
      )

      assert_equal database, actual
      assert_not root.join("storage", CampfireBackup::InstallationIdentity::FILENAME).exist?
    end

    with_production_connection(connection_relative_path: "storage/db/divergent.sqlite3") do |root, _database, _build_identity_path, connection|
      error = assert_raises(RuntimeError) do
        CampfireBackup::UpgradeRecoveryGuard.verify_backup_target!(
          connection:, storage_directory: root.join("storage"),
          env: { "RAILS_ENV" => "production" }, root:
        )
      end

      assert_match "Active Record production database does not match", error.message
      assert_not root.join("storage", CampfireBackup::InstallationIdentity::FILENAME).exist?
    end
  end

  test "backup target validation rejects a pathname that replaced the open database inode" do
    with_production_connection do |root, database, _build_identity_path, connection|
      connection.execute("PRAGMA user_version")
      opened_database = root.join("opened-production.sqlite3")
      File.rename database, opened_database
      create_legacy_database database
      SQLite3::Database.open(database.to_s) do |replacement|
        replacement.execute("CREATE TABLE replacement_only (id integer)")
      end

      error = assert_raises(RuntimeError) do
        UpgradeRecoveryGuard.verify_backup_target!(
          connection:, storage_directory: root.join("storage"),
          env: { "RAILS_ENV" => "production" }, root:
        )
      end

      assert_match "main database file moved", error.message
      assert_not connection.table_exists?(:replacement_only)
    end
  end

  test "SQLite connection identity records and revalidates the actual open descriptor" do
    with_production_connection do |root, database, _build_identity_path, connection|
      identity = connection.raw_connection.instance_variable_get(
        CampfireBackup::UpgradeRecoveryGuard::SQLITE_CONNECTION_IDENTITY_IVAR
      )

      assert_kind_of Integer, identity.fetch(:descriptor)
      assert_equal identity.fetch(:target_identity), identity.fetch(:descriptor_identity)
      assert_equal identity, CampfireBackup::UpgradeRecoveryGuard.assert_database_connection_semantics!(
        connection:, expected_database: database, root:
      )
    end
  end

  test "a byte-identical SQLite ABA is rejected before the detached database is mutated" do
    Dir.mktmpdir("campfire-production-aba") do |directory|
      root = Pathname(directory)
      database = root.join("production.sqlite3")
      detached_database = root.join("detached.sqlite3")
      displaced_database = root.join("canonical.sqlite3")
      create_legacy_database database
      FileUtils.copy_file database, detached_database
      adapter = sqlite_identity_adapter do |config|
        begin
          File.rename database, displaced_database
          File.rename detached_database, database
          SQLite3::Database.new(config.fetch(:database).to_s)
        ensure
          File.rename database, detached_database if database.exist?
          File.rename displaced_database, database if displaced_database.exist?
        end
      end
      mutated = false

      error = assert_raises(RuntimeError) do
        client = adapter.new_client(database: database.to_s)
        client.execute("CREATE TABLE aba_must_not_report_success (id integer)")
        mutated = true
      end

      assert_match "main database file moved", error.message
      assert_not mutated
      canonical = SQLite3::Database.new(database.to_s, readonly: true)
      assert_empty canonical.table_info("aba_must_not_report_success")
      detached = SQLite3::Database.new(detached_database.to_s, readonly: true)
      assert_empty detached.table_info("aba_must_not_report_success")
    ensure
      canonical&.close
      detached&.close
    end
  end

  test "native SQLite identity rejects exact descriptor reuse hidden by a same-path decoy" do
    Dir.mktmpdir("campfire-production-descriptor-aba") do |directory|
      root = Pathname(directory)
      database = root.join("production.sqlite3")
      detached_database = root.join("detached.sqlite3")
      displaced_database = root.join("canonical.sqlite3")
      create_legacy_database database
      FileUtils.copy_file database, detached_database
      reused = File.open(detached_database, "rb")
      reused_descriptor = reused.fileno
      descriptor_was_reused = false
      decoy = nil
      adapter = sqlite_identity_adapter do |config|
        begin
          reused.close
          File.rename database, displaced_database
          File.rename detached_database, database
          client = SQLite3::Database.new(config.fetch(:database).to_s)
          current = database.lstat
          descriptor_was_reused = CampfireBackup::UpgradeRecoveryGuard
            .sqlite_descriptor_metadata(reused_descriptor)
            &.fetch(:identity) == [ current.dev, current.ino, current.ftype ]
          File.rename database, detached_database
          File.rename displaced_database, database
          decoy = File.open(database, "rb")
          client
        ensure
          if displaced_database.exist?
            File.rename database, detached_database if database.exist?
            File.rename displaced_database, database
          end
        end
      end
      mutated = false

      error = assert_raises(RuntimeError) do
        client = adapter.new_client(database: database.to_s)
        client.execute("CREATE TABLE descriptor_aba_must_not_commit (id integer)")
        mutated = true
      end

      current = database.lstat
      if descriptor_was_reused
        assert_equal [ current.dev, current.ino, current.ftype ],
          CampfireBackup::UpgradeRecoveryGuard.sqlite_descriptor_metadata(decoy.fileno).fetch(:identity)
      end
      assert_match "main database file moved", error.message
      assert_not mutated
      canonical = SQLite3::Database.new(database.to_s, readonly: true)
      assert_empty canonical.table_info("descriptor_aba_must_not_commit")
      detached = SQLite3::Database.new(detached_database.to_s, readonly: true)
      assert_empty detached.table_info("descriptor_aba_must_not_commit")
    ensure
      reused&.close unless reused&.closed?
      decoy&.close
      canonical&.close
      detached&.close
    end
  end

  test "connection-specific descriptors disambiguate identical snapshots without accepting old clients" do
    identity = [ 1, 2, "file" ].freeze
    metadata = { identity:, target: nil }.freeze
    snapshot = { 17 => metadata }.freeze

    opened = CampfireBackup::UpgradeRecoveryGuard.identify_opened_sqlite_descriptor!(
      snapshot, snapshot,
      expected_identity: identity, expected_path: "/storage/db/production.sqlite3",
      connection_descriptor: 17, preexisting_client: false
    )

    assert_equal 17, opened.fetch(:descriptor)
    assert_equal identity, opened.fetch(:identity)
    assert_raises(RuntimeError) do
      CampfireBackup::UpgradeRecoveryGuard.identify_opened_sqlite_descriptor!(
        snapshot, snapshot,
        expected_identity: identity, expected_path: "/storage/db/production.sqlite3",
        connection_descriptor: 17, preexisting_client: true
      )
    end
  end

  test "production fails closed when the SQLite main descriptor is ambiguous" do
    Dir.mktmpdir("campfire-production-descriptor-ambiguity") do |directory|
      database = Pathname(directory).join("production.sqlite3")
      create_legacy_database database
      existing_client = SQLite3::Database.new(database.to_s)
      adapter = sqlite_identity_adapter { existing_client }

      error = with_environment("RAILS_ENV" => "production") do
        assert_raises(RuntimeError) { adapter.new_client(database: database.to_s) }
      end

      assert_match "descriptor cannot be identified exactly", error.message
    ensure
      begin
        existing_client&.close
      rescue SQLite3::Exception
        nil
      end
    end
  end

  test "upgrade authorization rejects an unknown archive statement format" do
    with_paths do |storage, database, archive, authentication|
      replace_archive_statement(archive) do |evidence|
        evidence["format_version"] = 99
        CampfireBackup::Authentication.sign_statement(evidence, key: KEY)
      end

      error = assert_raises(RuntimeError) do
        guard(storage, database).authorize!(archive_path: archive, authentication_path: authentication)
      end

      assert_match "unsupported format version", error.message
      assert_not storage.join(UpgradeRecoveryGuard::RECEIPT_FILENAME).exist?
    end
  end

  test "schema verifier migration capability is exact-path and thread-local" do
    original_config = ActiveRecord::Base.connection_db_config
    Dir.mktmpdir("campfire-schema-capability") do |directory|
      root = Pathname(directory)
      database = root.join("verifier.sqlite3")
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: database.to_s)
      connection = ActiveRecord::Base.connection
      connection.execute "PRAGMA user_version"
      environment = { "RAILS_ENV" => "production" }

      CampfireBackup::UpgradeRecoveryGuard.with_schema_verifier_target(database) do
        assert_equal :schema_verifier, CampfireBackup::UpgradeRecoveryGuard.verify_migration!(
          connection:, env: environment, root:
        )
        thread_error = Thread.new do
          CampfireBackup::UpgradeRecoveryGuard.verify_migration!(
            connection:, env: environment, root:
          )
        rescue StandardError => error
          error
        end.value
        assert_instance_of ActiveRecord::MigrationError, thread_error
        assert_match(/does not match the guarded Campfire database|open database inode cannot be verified/,
          thread_error.message)
      end

      assert_raises(ActiveRecord::MigrationError) do
        CampfireBackup::UpgradeRecoveryGuard.verify_migration!(
          connection:, env: environment, root:
        )
      end
    end
  ensure
    ActiveRecord::Base.establish_connection original_config if original_config
  end

  private
    def with_paths(create_database: true, prepare_database: nil, prepare_storage: nil)
      Dir.mktmpdir("campfire-upgrade-guard") do |directory|
        root = Pathname(directory)
        storage = root.join("storage").tap(&:mkpath)
        database = storage.join("db/production.sqlite3")
        if create_database
          database.dirname.mkpath
          connection = SQLite3::Database.new(database.to_s)
          connection.execute("PRAGMA journal_mode = WAL")
          connection.execute("CREATE TABLE schema_migrations (version varchar NOT NULL PRIMARY KEY)")
          connection.execute("INSERT INTO schema_migrations (version) VALUES (?)", LEGACY_VERSION.to_s)
          prepare_database&.call(connection)
          connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
          connection.close
          storage.join(CampfireBackup::InstallationIdentity::FILENAME).write "#{IDENTIFIER}\n"
          prepare_storage&.call(storage)
        end
        recovery = root.join("recovery").tap(&:mkpath)
        if create_database
          generation = storage.join("backups", BACKUP_ID).tap(&:mkpath)
          snapshot = generation.join("production.sqlite3")
          create_snapshot database, snapshot
          payload = generation.join("payload").tap(&:mkpath)
          FileUtils.cp storage.join(CampfireBackup::InstallationIdentity::FILENAME), payload
          FileUtils.cp_r storage.join("files"), payload.join("files") if storage.join("files").directory?
          source_state = CampfireBackup::SourceStateInventory.capture(
            database: database, database_path: database, storage_directory: storage,
            environment: "production", backup_id: BACKUP_ID,
            installation_identifier: IDENTIFIER, schema_version: LEGACY_VERSION
          )
          assert_equal source_state.fetch("database").fetch("sha256"), Digest::SHA256.file(snapshot).hexdigest
          manifest = CampfireBackup::Authentication.sign_manifest({
            format_version: 1,
            backup_id: BACKUP_ID,
            created_at: NOW.iso8601,
            environment: "production",
            application_version: "1.2.3",
            schema_version: LEGACY_VERSION,
            installation_fingerprint: FINGERPRINT,
            database: {
              path: "production.sqlite3", bytes: snapshot.size,
              sha256: Digest::SHA256.file(snapshot).hexdigest,
              integrity_check: "ok", foreign_key_check: "ok"
            },
            files: source_state.fetch("storage_files"),
            source_state:
          }, key: KEY)
          generation.join("manifest.json").write JSON.pretty_generate(manifest)
          storage.join("backups/latest").make_symlink(BACKUP_ID)
          archived = nil
          capture_io do
            archived = BackupArchiver.archive(
              generation_path: generation, destination_directory: recovery,
              expected_installation_fingerprint: FINGERPRINT,
              expected_environment: "production", authentication_key: KEY,
              encryption_keyring: encryption_keyring,
              mount_identity_resolver: independent_archive_mount_resolver(recovery)
            )
          end
          archive = archived
          authentication = archive
        else
          archive = recovery.join("unused.tar.gz")
          authentication = recovery.join("unused.authentication.json")
        end
        yield storage, database, archive, authentication
      end
    end

    def guard(storage, database, revision: REVISION, build_id: Digest::SHA256.hexdigest("test-build\0#{REVISION}"),
        now: NOW, mount_identity_resolver: independent_mount_resolver(storage))
      UpgradeRecoveryGuard.new(
        storage_directory: storage, database_path: database, environment: "production",
        build_identity: {
          format_version: 1, revision:, build_identity: build_id
        },
        authentication_key: KEY, encryption_keyring:, now:, mount_identity_resolver:, root: Rails.root
      )
    end

    def independent_mount_resolver(storage)
      storage = Pathname(storage).realpath
      lambda do |path|
        path = Pathname(path).realpath
        storage_mount = path == storage || path.to_s.start_with?("#{storage}/")
        CampfireBackup::MountIdentity::Entry.new(
          mount_id: storage_mount ? 101 : 102, parent_id: 1, device: "8:1",
          root: storage_mount ? "/docker/volumes/campfire/_data" : "/docker/volumes/recovery/_data",
          mount_point: storage_mount ? storage.to_s : storage.dirname.realpath.to_s,
          filesystem_type: "ext4", source: "/dev/sda1"
        ).freeze
      end
    end

    def independent_archive_mount_resolver(destination)
      destination = Pathname(destination).realpath
      lambda do |path|
        path = Pathname(path).realpath
        archive_mount = path == destination || path.to_s.start_with?("#{destination}/")
        CampfireBackup::MountIdentity::Entry.new(
          mount_id: archive_mount ? 301 : 302, parent_id: 1,
          device: archive_mount ? "8:1" : "0:42", root: "/",
          mount_point: archive_mount ? destination.to_s : "/",
          filesystem_type: archive_mount ? "ext4" : "tmpfs",
          source: archive_mount ? "/dev/sda1" : "tmpfs"
        ).freeze
      end
    end

    def encryption_keyring
      CampfireBackup::BackupEncryption::Keyring.new(
        active_id: ENCRYPTION_KEY_ID, active_key: ENCRYPTION_KEY
      )
    end

    def create_snapshot(source_path, destination_path)
      source = SQLite3::Database.new(source_path.to_s, readonly: true)
      destination = SQLite3::Database.new(destination_path.to_s)
      backup = SQLite3::Backup.new(destination, "main", source, "main")
      backup.step(-1)
      backup.finish
      destination.execute("PRAGMA journal_mode = DELETE")
    ensure
      backup&.finish rescue nil
      destination&.close
      source&.close
    end

    def insert_schema_version(database, version)
      connection = SQLite3::Database.new(database.to_s)
      connection.execute("INSERT INTO schema_migrations (version) VALUES (?)", version.to_s)
      connection.close
    end

    def schema_versions(database)
      connection = SQLite3::Database.new(database.to_s, readonly: true)
      connection.execute("SELECT version FROM schema_migrations ORDER BY version").flatten
    ensure
      connection&.close
    end

    def replace_archive_statement(archive)
      replacement = archive.dirname.join("replacement.campfire-backup")
      Dir.mktmpdir("campfire-upgrade-statement") do |directory|
        CampfireBackup::BackupEncryption.with_decrypted_archive(
          archive, keyring: encryption_keyring, temporary_directory: directory
        ) do |plaintext_archive, authentication, _envelope|
          evidence = CampfireBackup::Authentication.verify_statement!(
            JSON.parse(authentication), key: KEY
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
      end
      archive.unlink
      File.rename replacement, archive
    end

    def with_production_connection(connection_relative_path: "storage/db/production.sqlite3")
      original_config = ActiveRecord::Base.connection_db_config
      Dir.mktmpdir("campfire-production-migration") do |directory|
        root = Pathname(directory)
        database = root.join("storage/db/production.sqlite3")
        connection_database = root.join(connection_relative_path)
        [ database, connection_database ].uniq.each { create_legacy_database(_1) }
        build_identity_path = root.join("campfire-build-identity.json")
        build_identity_path.write JSON.generate(
          format_version: 1, revision: REVISION,
          build_identity: Digest::SHA256.hexdigest("production-migration-test")
        )
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: connection_database.to_s)

        yield root, database, build_identity_path, ActiveRecord::Base.connection
      end
    ensure
      ActiveRecord::Base.establish_connection original_config if original_config
    end

    def sqlite_identity_adapter(&client_builder)
      Class.new do
        class << self
          attr_accessor :client_builder

          def resolve_path(path)
            path
          end

          def new_client(config)
            client_builder.call(config)
          end
        end
      end.tap do |adapter|
        adapter.client_builder = client_builder
        adapter.singleton_class.prepend(CampfireBackup::UpgradeRecoveryGuard::SQLiteClientIdentity)
      end
    end

    def create_legacy_database(path)
      path.dirname.mkpath
      database = SQLite3::Database.new(path.to_s)
      database.execute("CREATE TABLE schema_migrations (version varchar NOT NULL PRIMARY KEY)")
      database.execute("INSERT INTO schema_migrations (version) VALUES (?)", LEGACY_VERSION.to_s)
    ensure
      database&.close
    end

    def with_environment(values)
      previous = values.to_h { |key, _| [ key, ENV[key] ] }
      values.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      yield
    ensure
      previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end
end
