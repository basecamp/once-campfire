require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "sqlite3"
require "time"
require "tmpdir"
require_relative "authentication"
require_relative "backup_encryption"
require_relative "build_identity"
require_relative "installation_identity"
require_relative "mount_identity"
require_relative "operation_lock"
require_relative "source_state_inventory"

module CampfireBackup
  SQLITE_NATIVE_LOAD_ERROR = begin
    require "campfire_sqlite_native"
    nil
  rescue LoadError, StandardError => error
    error
  end

  class UpgradeRecoveryGuard
    GATED_MIGRATION = 20260730000000
    RECEIPT_FILENAME = "upgrade-recovery.json"
    RECEIPT_LIFETIME = 24 * 60 * 60
    FRESHNESS_TABLES = %w[ accounts users rooms messages active_storage_blobs ].freeze
    FRESHNESS_INTERNAL_TABLES = %w[ ar_internal_metadata schema_migrations sqlite_sequence ].freeze
    SQLITE_CONNECTION_IDENTITY_IVAR = :@campfire_open_database_identity
    SCHEMA_VERIFIER_TARGETS_KEY = :campfire_schema_verifier_migration_targets
    MIGRATION_CONTEXT_TARGETS_KEY = :campfire_verified_migration_context_targets
    MIGRATION_OPERATION_KEY = :campfire_migration_operation
    DATABASE_TASKS_MIGRATION_KEY = :campfire_database_tasks_migration
    TRUSTED_MIGRATION_SELECTION_KEY = :campfire_trusted_migration_selection
    SQLITE_CONNECTION_OPEN_MUTEX = Mutex.new
    SQLITE_DESCRIPTOR_DIRECTORIES = %w[ /proc/self/fd /dev/fd ].freeze

    module SQLiteClientIdentity
      def new_client(config)
        configured = config[:database].to_s
        return super if configured == ":memory:" || configured.match?(/(?:\?|&)mode=memory(?:&|\z)/)

        CampfireBackup::UpgradeRecoveryGuard::SQLITE_CONNECTION_OPEN_MUTEX.synchronize do
          requested = Pathname(resolve_path(configured)).expand_path
          raise "Active Record SQLite database cannot be a symbolic link" if requested.symlink?

          parent = requested.dirname.realpath
          canonical = parent.join(requested.basename)
          flags = config[:readonly] ? File::RDONLY : File::RDWR | File::CREAT
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          client = nil
          File.open(canonical, flags, 0o600) do |pinned|
            pinned_stat = pinned.stat
            parent_identity = file_identity(parent)
            unless pinned_stat.file? && pinned_stat.nlink == 1
              raise "Active Record SQLite database is not an independent regular file"
            end

            descriptors_before = CampfireBackup::UpgradeRecoveryGuard.sqlite_descriptor_snapshot
            # Exact descriptor reuse can leave identical snapshots; still require this call to construct the client.
            constructed_clients = []
            construction_trace = TracePoint.new(:c_return) do |event|
              if event.method_id == :new && event.return_value.is_a?(SQLite3::Database)
                constructed_clients << event.return_value
              end
            end
            client = construction_trace.enable(target_thread: Thread.current) { super(config) }
            CampfireBackup::UpgradeRecoveryGuard.assert_sqlite_main_file_current!(client)
            opened_filename = canonical_path(client.filename("main"))
            connection_descriptor = CampfireBackup::UpgradeRecoveryGuard.sqlite_main_file_descriptor!(client)
            descriptors_after = CampfireBackup::UpgradeRecoveryGuard.sqlite_descriptor_snapshot
            pinned_identity = [ pinned_stat.dev, pinned_stat.ino, pinned_stat.ftype ].freeze
            opened_descriptor = CampfireBackup::UpgradeRecoveryGuard.identify_opened_sqlite_descriptor!(
              descriptors_before, descriptors_after,
              expected_identity: pinned_identity, expected_path: opened_filename,
              connection_descriptor:,
              preexisting_client: constructed_clients.none? { _1.equal?(client) }
            )
            current_stat = canonical.lstat
            unless opened_filename == canonical && file_identity(parent) == parent_identity &&
                [ current_stat.dev, current_stat.ino, current_stat.ftype ] == pinned_identity
              raise "Active Record SQLite database changed while its connection was opened"
            end
            if opened_descriptor && opened_descriptor.fetch(:identity) != pinned_identity
              raise "Active Record SQLite opened a different database inode than the guarded Campfire database"
            end

            client.instance_variable_set(SQLITE_CONNECTION_IDENTITY_IVAR, {
              path: canonical.to_s,
              parent_identity:,
              target_identity: pinned_identity,
              descriptor: opened_descriptor&.fetch(:descriptor),
              descriptor_identity: opened_descriptor&.fetch(:identity),
              pid: Process.pid
            }.freeze)
          end
          client
        rescue Exception
          client&.close
          raise
        end
      end

      private
        def canonical_path(path)
          path = Pathname(path).expand_path
          path.dirname.realpath.join(path.basename)
        end

        def file_identity(path)
          stat = path.lstat
          [ stat.dev, stat.ino, stat.ftype ]
        end
    end

    class GuardedMigrator
      def initialize(builder:, guard:)
        @builder = builder
        @guard = guard
      end

      def method_missing(name, ...)
        @guard.call { migrator.public_send(name, ...) }
      end

      def respond_to_missing?(name, include_private = false)
        !@migrator || @migrator.respond_to?(name, include_private) || super
      end

      private
        def migrator
          @migrator ||= @builder.call
        end
    end

    module DatabaseTasksMigrationGuard
      def migrate(...)
        CampfireBackup::UpgradeRecoveryGuard.with_database_tasks_migration { super }
      end
    end

    module MigrationContextGuard
      def migrate(target_version = nil, &selection)
        if selection && CampfireBackup::UpgradeRecoveryGuard.database_tasks_migration?
          CampfireBackup::UpgradeRecoveryGuard.with_trusted_migration_selection(self) { super }
        else
          super
        end
      end

      def up(target_version = nil, &selection)
        with_verified_campfire_migration_target! do
          selected_versions = isolated_selected_versions(selection)
          super(target_version) { |migration| selected_versions.include?(migration.version) }
        end
      end

      def down(target_version = nil, &selection)
        with_verified_campfire_migration_target! do
          selected_versions = isolated_selected_versions(selection)
          super(target_version) { |migration| selected_versions.include?(migration.version) }
        end
      end

      def run(direction, target_version)
        with_verified_campfire_migration_target! { super }
      end

      def rollback(steps = 1)
        with_verified_campfire_migration_target! { super }
      end

      def forward(steps = 1)
        with_verified_campfire_migration_target! { super }
      end

      def open
        GuardedMigrator.new(
          builder: -> { ActiveRecord::Migrator.new(:up, migrations, schema_migration, internal_metadata) },
          guard: ->(&operation) { with_verified_campfire_migration_target!(&operation) }
        )
      end

      private
        def isolated_selected_versions(selection)
          if selection && CampfireBackup::UpgradeRecoveryGuard.production_environment? &&
              !CampfireBackup::UpgradeRecoveryGuard.trusted_migration_selection?(self)
            raise ActiveRecord::MigrationError, "Production migration selection blocks are unsupported"
          end
          return migrations.map(&:version) unless selection

          pool = schema_migration.instance_variable_get(:@pool)
          unless pool.respond_to?(:with_connection)
            raise ActiveRecord::MigrationError, "Active Record migration selection cannot be isolated"
          end
          selected = nil
          pool.with_connection do |connection|
            connection.transaction(requires_new: true) do
              selected = migrations.select { |migration| selection.call(migration) }.map(&:version)
              raise ActiveRecord::Rollback
            end
          end
          selected
        end

        def move(direction, steps)
          with_verified_campfire_migration_target! { super }
        end

        def with_verified_campfire_migration_target!
          CampfireBackup::UpgradeRecoveryGuard.with_verified_migration(schema_migration) { yield }
        end
    end

    module MigratorGuard
      def initialize(direction, migrations, schema_migration, internal_metadata, target_version = nil)
        CampfireBackup::UpgradeRecoveryGuard.assert_migrator_construction!(schema_migration)
        super
      end

      def migrate
        CampfireBackup::UpgradeRecoveryGuard.with_verified_migration(@schema_migration) { super }
      end

      def run
        CampfireBackup::UpgradeRecoveryGuard.with_verified_migration(@schema_migration) { super }
      end

      private
        def migrate_without_lock
          CampfireBackup::UpgradeRecoveryGuard.with_verified_migration(@schema_migration) { super }
        end

        def run_without_lock
          CampfireBackup::UpgradeRecoveryGuard.with_verified_migration(@schema_migration) { super }
        end

        def record_environment
          CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection)
          super
        end

        def execute_migration_in_transaction(migration)
          CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection)
          super.tap { CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection) }
        end

        def ddl_transaction(migration, &operation)
          super(migration) do
            CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection)
            operation.call.tap do
              CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection)
            end
          end
        end

        def record_version_state_after_migrating(version)
          CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection)
          super
        end
    end

    module MigrationGuard
      def migrate(direction)
        guarded = direction.to_sym.in?([ :up, :down ])
        CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection) if guarded
        super.tap do
          CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection) if guarded
        end
      end

      def exec_migration(connection, direction)
        guarded = direction.to_sym.in?([ :up, :down ])
        CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection) if guarded
        super.tap do
          CampfireBackup::UpgradeRecoveryGuard.assert_migration_boundary!(connection) if guarded
        end
      end
    end

    class << self
      def install_active_record_guards!
        require "active_record/tasks/database_tasks"

        context_guard = MigrationContextGuard
        ActiveRecord::MigrationContext.prepend(context_guard) unless ActiveRecord::MigrationContext < context_guard
        migrator_guard = MigratorGuard
        ActiveRecord::Migrator.prepend(migrator_guard) unless ActiveRecord::Migrator < migrator_guard
        migration_guard = MigrationGuard
        ActiveRecord::Migration.prepend(migration_guard) unless ActiveRecord::Migration < migration_guard
        database_tasks_guard = DatabaseTasksMigrationGuard
        database_tasks_singleton = ActiveRecord::Tasks::DatabaseTasks.singleton_class
        unless database_tasks_singleton < database_tasks_guard
          database_tasks_singleton.prepend(database_tasks_guard)
        end
      end

      def with_database_tasks_migration
        previous = Thread.current.thread_variable_get(DATABASE_TASKS_MIGRATION_KEY)
        capability = { pid: Process.pid, token: Object.new }.freeze
        Thread.current.thread_variable_set(DATABASE_TASKS_MIGRATION_KEY, capability)
        yield
      ensure
        Thread.current.thread_variable_set(DATABASE_TASKS_MIGRATION_KEY, previous)
      end

      def database_tasks_migration?
        capability = Thread.current.thread_variable_get(DATABASE_TASKS_MIGRATION_KEY)
        capability.is_a?(Hash) && capability[:pid] == Process.pid
      end

      def with_trusted_migration_selection(context)
        capability = Thread.current.thread_variable_get(DATABASE_TASKS_MIGRATION_KEY)
        unless capability.is_a?(Hash) && capability[:pid] == Process.pid
          raise ActiveRecord::MigrationError, "Active Record database task selection is not authorized"
        end

        previous = Thread.current.thread_variable_get(TRUSTED_MIGRATION_SELECTION_KEY)
        trusted = { pid: Process.pid, context_id: context.object_id, token: capability.fetch(:token) }.freeze
        Thread.current.thread_variable_set(TRUSTED_MIGRATION_SELECTION_KEY, trusted)
        yield
      ensure
        Thread.current.thread_variable_set(TRUSTED_MIGRATION_SELECTION_KEY, previous)
      end

      def trusted_migration_selection?(context)
        capability = Thread.current.thread_variable_get(DATABASE_TASKS_MIGRATION_KEY)
        trusted = Thread.current.thread_variable_get(TRUSTED_MIGRATION_SELECTION_KEY)
        capability.is_a?(Hash) && trusted.is_a?(Hash) &&
          capability[:pid] == Process.pid && trusted[:pid] == Process.pid &&
          trusted[:context_id] == context.object_id && trusted[:token].equal?(capability[:token])
      end

      def install_sqlite_connection_identity!(adapter)
        singleton = adapter.singleton_class
        singleton.prepend(SQLiteClientIdentity) unless singleton < SQLiteClientIdentity
      end

      def sqlite_descriptor_snapshot
        directory = SQLITE_DESCRIPTOR_DIRECTORIES.find { File.directory?(_1) }
        unless directory
          raise "Active Record SQLite descriptor identity is unsupported on this platform" if RUBY_PLATFORM.match?(/linux|darwin/)

          return
        end

        Dir.children(directory).grep(/\A\d+\z/).each_with_object({}) do |name, descriptors|
          descriptor = Integer(name, 10)
          metadata = sqlite_descriptor_metadata(descriptor, directory:)
          descriptors[descriptor] = metadata if metadata
        end.freeze
      end

      def identify_opened_sqlite_descriptor!(before, after, expected_identity:, expected_path:,
          connection_descriptor: nil, preexisting_client: false)
        if connection_descriptor
          metadata = after&.fetch(connection_descriptor, nil)
          unless !preexisting_client && metadata && metadata.fetch(:identity).last == "file" &&
              metadata.fetch(:identity) == expected_identity &&
              (!metadata.fetch(:target) || metadata.fetch(:target) == expected_path.to_s)
            raise "Active Record SQLite main database descriptor cannot be identified exactly"
          end

          return metadata.merge(descriptor: connection_descriptor).freeze
        end

        unless before && after
          raise "Active Record SQLite descriptor identity cannot be established in production" if production_environment?

          return
        end

        candidates = after.filter_map do |descriptor, metadata|
          metadata.merge(descriptor:) if metadata.fetch(:identity).last == "file" && before[descriptor] != metadata
        end
        return candidates.first.freeze if candidates.one?

        path_matches = candidates.select { _1.fetch(:target) == expected_path.to_s }
        return path_matches.first.freeze if path_matches.one?

        unless production_environment?
          identity_matches = candidates.select { _1.fetch(:identity) == expected_identity }
          return identity_matches.first.freeze if identity_matches.one?
        end

        raise "Active Record SQLite main database descriptor cannot be identified exactly"
      end

      def sqlite_main_file_descriptor!(database)
        return if SQLITE_NATIVE_LOAD_ERROR

        CampfireSQLiteNative.main_database_descriptor(database)
      rescue StandardError => error
        raise "Active Record SQLite native main descriptor cannot be verified: #{error.message}"
      end

      def sqlite_descriptor_metadata(descriptor, directory: nil)
        directory ||= SQLITE_DESCRIPTOR_DIRECTORIES.find { File.directory?(_1) }
        return unless directory

        stat = IO.for_fd(descriptor, autoclose: false).stat
        target = File.readlink(File.join(directory, descriptor.to_s))
        {
          identity: [ stat.dev, stat.ino, stat.ftype ].freeze,
          target:
        }.freeze
      rescue ArgumentError, Errno::EBADF, Errno::ENOENT, Errno::EINVAL
        if defined?(stat) && stat
          {
            identity: [ stat.dev, stat.ino, stat.ftype ].freeze,
            target: nil
          }.freeze
        end
      end

      def production_environment?
        ENV["RAILS_ENV"] == "production" || (defined?(Rails) && Rails.env.production?)
      end

      def assert_sqlite_main_file_current!(database)
        if SQLITE_NATIVE_LOAD_ERROR
          if production_environment?
            raise "Active Record SQLite native main-file identity verification is unavailable: " \
              "#{SQLITE_NATIVE_LOAD_ERROR.message}"
          end

          return true
        end

        moved = begin
          CampfireSQLiteNative.main_database_moved?(database)
        rescue StandardError => error
          raise "Active Record SQLite native main-file identity cannot be verified: #{error.message}"
        end
        if moved
          raise "Active Record SQLite main database file moved after its connection was opened"
        end

        true
      end

      def with_verified_migration(schema_migration)
        pool = schema_migration.instance_variable_get(:@pool)
        unless pool.respond_to?(:with_connection)
          raise ActiveRecord::MigrationError, "Active Record migration connection cannot be verified"
        end

        pool.with_connection do |connection|
          with_migration_operation(connection:) do
            authorization = verify_migration!(connection:)
            if authorization.in?([ :not_production, :schema_verifier ])
              yield
            else
              with_migration_context_target(connection) do
                yield.tap { complete_migration_context_target(connection) }
              end
            end
          end
        end
      end

      def with_migration_operation(connection:, env: ENV, root: Rails.root)
        if Thread.current.thread_variable_get(MIGRATION_OPERATION_KEY)
          assert_migration_boundary!(connection, env:, root:)
          return yield
        end

        root = Pathname(root).expand_path
        environment = env.fetch("RAILS_ENV", Rails.env.to_s)
        actual_database = active_record_target(connection, root)
        initial_identity = assert_active_record_target!(connection, actual_database, root)
        schema_verifier = schema_verifier_target?(actual_database)
        operation_lock = nil

        if environment == "production" && !schema_verifier
          expected_database = root.join("storage/db/production.sqlite3")
          assert_active_record_target!(connection, expected_database, root)
          storage_directory = root.join("storage")
          inherited_descriptors = inherited_operation_lock_descriptors(storage_directory)
          operation_lock = OperationLock.acquire(
            storage_directory, purpose: "migration", shared: true,
            **inherited_descriptors
          )
        end

        identity = if environment == "production" && !schema_verifier
          assert_active_record_semantics!(
            connection, actual_database, root, expected_identity: initial_identity
          )
        else
          assert_active_record_target!(
            connection, actual_database, root, expected_identity: initial_identity
          )
        end
        context = {
          pid: Process.pid,
          database_path: canonical_database_path(actual_database).to_s,
          database_identity: identity,
          operation_lock:
        }
        previous = Thread.current.thread_variable_get(MIGRATION_OPERATION_KEY)
        Thread.current.thread_variable_set(MIGRATION_OPERATION_KEY, context)
        assert_migration_boundary!(connection, env:, root:)
        result = yield
        if environment == "production" && !schema_verifier
          assert_active_record_semantics!(
            connection, actual_database, root, expected_identity: identity
          )
          operation_lock.assert_current!
        end
        result
      ensure
        if defined?(context) && context
          Thread.current.thread_variable_set(MIGRATION_OPERATION_KEY, previous)
          operation_lock&.release
        elsif defined?(operation_lock)
          operation_lock&.release
        end
      end

      def assert_migrator_construction!(schema_migration, env: ENV, root: Rails.root)
        environment = env.fetch("RAILS_ENV", defined?(Rails) ? Rails.env.to_s : "development")
        return true unless environment == "production"
        unless Thread.current.thread_variable_get(MIGRATION_OPERATION_KEY)
          raise ActiveRecord::MigrationError,
            "Production migrations must run through the guarded Active Record migration context"
        end

        pool = schema_migration.instance_variable_get(:@pool)
        unless pool.respond_to?(:with_connection)
          raise ActiveRecord::MigrationError, "Active Record migration connection cannot be verified"
        end
        pool.with_connection { |connection| assert_migration_boundary!(connection, env:, root:) }

        true
      end

      def assert_migration_boundary!(connection, env: ENV, root: Rails.root)
        root = Pathname(root).expand_path
        context = Thread.current.thread_variable_get(MIGRATION_OPERATION_KEY)
        if context
          unless context.fetch(:pid) == Process.pid
            raise ActiveRecord::MigrationError, "Production migration operation belongs to another process"
          end
          identity = assert_active_record_target!(
            connection, Pathname(context.fetch(:database_path)), root,
            expected_identity: context.fetch(:database_identity)
          )
          context.fetch(:operation_lock)&.assert_current!
          return identity
        end

        actual_database = active_record_target(connection, root)
        if schema_verifier_target?(actual_database)
          return assert_active_record_target!(connection, actual_database, root)
        end
        environment = env.fetch("RAILS_ENV", Rails.env.to_s)
        return true unless environment == "production"

        raise ActiveRecord::MigrationError,
          "Production migrations must run through the guarded Active Record migration context"
      rescue RuntimeError => error
        raise ActiveRecord::MigrationError, error.message
      end

      def assert_database_connection!(connection:, expected_database:, root: Rails.root,
          expected_identity: nil)
        assert_active_record_target!(
          connection, Pathname(expected_database).expand_path(root), Pathname(root).expand_path,
          expected_identity:
        )
      end

      def assert_database_connection_semantics!(connection:, expected_database:, root: Rails.root,
          expected_identity: nil)
        root = Pathname(root).expand_path
        assert_active_record_semantics!(
          connection, Pathname(expected_database).expand_path(root), root, expected_identity:
        )
      end

      def from_environment(env = ENV, now: Time.now.utc, connection: nil,
          root: Pathname(File.expand_path("../..", __dir__)), build_identity_path: BuildIdentity::PATH)
        root = Pathname(root).expand_path
        environment = env.fetch("RAILS_ENV", "development")
        expected_storage = root.join("storage").expand_path
        expected_database = expected_storage.join("db", "#{environment}.sqlite3")
        storage_directory = Pathname(env.fetch("CAMPFIRE_STORAGE_PATH", expected_storage.to_s)).expand_path
        database_path = Pathname(env.fetch("CAMPFIRE_DATABASE_PATH", expected_database.to_s)).expand_path

        if environment == "production"
          raise "DATABASE_URL is unsupported for the production Campfire database" unless env["DATABASE_URL"].to_s.empty?
          unless storage_directory == expected_storage && database_path == expected_database
            raise "Production Campfire storage and database paths cannot be overridden"
          end
          if expected_storage.symlink? || expected_database.dirname.symlink? || expected_database.symlink?
            raise "Production Campfire storage and database paths cannot be symbolic links"
          end
          marker = Pathname(env.fetch(
            "CAMPFIRE_INSTALLATION_IDENTIFIER_PATH",
            expected_storage.join(InstallationIdentity::FILENAME).to_s
          )).expand_path
          unless marker == expected_storage.join(InstallationIdentity::FILENAME)
            raise "Production Campfire installation identity path cannot be overridden"
          end
          assert_active_record_target! connection, expected_database, root if connection
          build_identity = BuildIdentity.read!(path: build_identity_path, environment_revision: env["GIT_REVISION"])
        else
          build_identity = {
            "format_version" => 1,
            "revision" => env["GIT_REVISION"].to_s,
            "build_identity" => "development"
          }
        end

        new(
          storage_directory:, database_path:, environment:, build_identity:,
          authentication_key: nil, authentication_environment: env, now:, root:
        )
      end

      def verify_migration!(connection:, env: ENV, now: Time.now.utc,
          root: Rails.root, build_identity_path: BuildIdentity::PATH)
        root = Pathname(root).expand_path
        environment = env.fetch("RAILS_ENV", Rails.env.to_s)
        expected_database = root.join("storage/db/production.sqlite3")
        actual_database = active_record_target(connection, root)
        return :migration_context if migration_context_target?(actual_database)
        return :schema_verifier if schema_verifier_target?(actual_database)

        if environment != "production"
          if same_database_target?(actual_database, expected_database)
            raise "The production Campfire database cannot be migrated outside RAILS_ENV=production"
          end
          return :not_production
        end

        authorization = from_environment(
          env, now:, connection:, root:, build_identity_path:
        ).verify_before_prepare!(connection:, full_archive_validation: false)
        unless Thread.current.thread_variable_get(MIGRATION_OPERATION_KEY)
          raise "Production migrations must run through the guarded Active Record migration context"
        end
        authorization
      rescue StandardError => error
        raise ActiveRecord::MigrationError, "Upgrade recovery authorization failed: #{error.message}"
      end

      def authorize_destructive_rollback!(migration:, env: ENV)
        environment = env.fetch("RAILS_ENV", defined?(Rails) ? Rails.env.to_s : "development")
        return :not_production unless environment == "production"

        raise ActiveRecord::IrreversibleMigration,
          "Production rollback of #{migration} requires a separately authenticated rollback archive " \
            "and target-build authorization; no such authorization is available"
      end

      def verify_backup_target!(connection:, storage_directory:, env: ENV, root: Rails.root)
        root = Pathname(root).expand_path
        environment = env.fetch("RAILS_ENV", Rails.env.to_s)
        actual_database = active_record_target(connection, root)
        expected_storage = root.join("storage")
        expected_database = expected_storage.join("db/production.sqlite3")
        if environment != "production"
          if same_database_target?(actual_database, expected_database)
            raise "The production Campfire database cannot be backed up outside RAILS_ENV=production"
          end
          return actual_database
        end

        storage_directory = Pathname(storage_directory).expand_path
        configured_storage = Pathname(env.fetch("CAMPFIRE_STORAGE_PATH", expected_storage.to_s)).expand_path
        configured_database = Pathname(env.fetch("CAMPFIRE_DATABASE_PATH", expected_database.to_s)).expand_path
        raise "DATABASE_URL is unsupported for the production Campfire database" unless env["DATABASE_URL"].to_s.empty?
        unless storage_directory == expected_storage && configured_storage == expected_storage &&
            configured_database == expected_database
          raise "Production Campfire storage and database paths cannot be overridden"
        end
        if expected_storage.symlink? || expected_database.dirname.symlink? || expected_database.symlink?
          raise "Production Campfire storage and database paths cannot be symbolic links"
        end

        assert_active_record_target! connection, expected_database, root
        actual_database
      end

      def with_schema_verifier_target(path)
        previous = Thread.current.thread_variable_get(SCHEMA_VERIFIER_TARGETS_KEY)
        path = Pathname(path).expand_path
        parent = path.dirname.realpath
        parent_stat = parent.lstat
        unless parent_stat.directory? && parent_stat.uid == Process.euid && (parent_stat.mode & 0o077).zero?
          raise "Schema verifier migration directory is not operation-owned"
        end
        canonical_path = parent.join(path.basename)
        if canonical_path.exist? || canonical_path.symlink?
          stat = canonical_path.lstat
          unless stat.file? && !stat.symlink? && stat.nlink == 1
            raise "Schema verifier migration target is not an independent regular file"
          end
        end

        capability = {
          path: canonical_path.to_s,
          parent_identity: path_identity(parent),
          target_identity: canonical_path.exist? ? path_identity(canonical_path) : nil
        }
        Thread.current.thread_variable_set(SCHEMA_VERIFIER_TARGETS_KEY, Array(previous) + [ capability ])
        yield
      ensure
        Thread.current.thread_variable_set(SCHEMA_VERIFIER_TARGETS_KEY, previous)
      end

      def with_migration_context_target(connection, root: Rails.root)
        path = active_record_target(connection, Pathname(root).expand_path)
        add_target_capability(MIGRATION_CONTEXT_TARGETS_KEY, path)
        yield
      ensure
        remove_target_capability(MIGRATION_CONTEXT_TARGETS_KEY, path) if path
      end

      def complete_migration_context_target(connection, root: Rails.root)
        applied = connection.table_exists?("schema_migrations") && connection.select_value(<<~SQL)
          SELECT 1 FROM schema_migrations WHERE version = '#{GATED_MIGRATION}' LIMIT 1
        SQL
        return unless applied

        path = active_record_target(connection, Pathname(root).expand_path)
        remove_target_capability(MIGRATION_CONTEXT_TARGETS_KEY, path)
      end

      private
        def active_record_target(connection, root)
          Pathname(connection.pool.db_config.database).expand_path(root)
        rescue NoMethodError, TypeError, ArgumentError
          raise "Active Record database target cannot be verified"
        end

        def canonical_database_path(path)
          path = Pathname(path).expand_path
          path.dirname.realpath.join(path.basename)
        end

        def inherited_operation_lock_descriptors(storage_directory)
          file_descriptor = ENV[OperationLock::INHERITED_FILE_FD_ENV].to_s
          shared_descriptor = ENV[OperationLock::INHERITED_SHARED_FD_ENV].to_s
          target = ENV[OperationLock::INHERITED_SHARED_TARGET_ENV].to_s
          inherited_root = ENV[OperationLock::INHERITED_LOCK_ROOT_ENV].to_s
          inherited = [ file_descriptor, shared_descriptor, target, inherited_root ]
          return {} if inherited.all?(&:empty?)
          if inherited.any?(&:empty?) ||
              canonical_database_path(target) != canonical_database_path(storage_directory) ||
              Pathname(inherited_root).expand_path != OperationLock.lock_root
            raise "Inherited Campfire operation lock does not match production storage"
          end

          {
            inherited_file_fd: Integer(file_descriptor, 10),
            inherited_shared_fd: Integer(shared_descriptor, 10)
          }
        rescue ArgumentError
          raise "Inherited Campfire operation lock descriptor is invalid"
        end

        def same_database_target?(actual, expected)
          actual == expected || (actual.exist? && expected.exist? && File.identical?(actual, expected))
        end

        def schema_verifier_target?(actual)
          target_capability?(SCHEMA_VERIFIER_TARGETS_KEY, actual)
        end

        def migration_context_target?(actual)
          Thread.current.thread_variable_get(MIGRATION_OPERATION_KEY) &&
            target_capability?(MIGRATION_CONTEXT_TARGETS_KEY, actual)
        end

        def target_capability?(key, actual)
          capabilities = Thread.current.thread_variable_get(key)
          return false if capabilities.nil? || actual.symlink?

          parent = actual.dirname.realpath
          canonical_path = parent.join(actual.basename)
          capabilities.any? do |capability|
            next false unless capability.fetch(:path) == canonical_path.to_s &&
              capability.fetch(:parent_identity) == path_identity(parent)

            current_target = actual.lstat
            next false unless current_target.file? && !current_target.symlink? && current_target.nlink == 1

            identity = [ current_target.dev, current_target.ino, current_target.ftype ]
            capability[:target_identity] ||= identity
            capability.fetch(:target_identity) == identity
          end
        rescue Errno::ENOENT
          false
        end

        def add_target_capability(key, path)
          path = Pathname(path).expand_path
          parent = path.dirname.realpath
          capability = {
            path: parent.join(path.basename).to_s,
            parent_identity: path_identity(parent),
            target_identity: path.exist? ? path_identity(path) : nil
          }
          capabilities = Array(Thread.current.thread_variable_get(key))
          unless capabilities.any? { _1 == capability }
            Thread.current.thread_variable_set(key, capabilities + [ capability ])
          end
          capability
        end

        def remove_target_capability(key, path)
          path = Pathname(path).expand_path
          parent = path.dirname.realpath
          canonical_path = parent.join(path.basename).to_s
          capabilities = Array(Thread.current.thread_variable_get(key))
          capabilities = capabilities.reject { _1.fetch(:path) == canonical_path }
          Thread.current.thread_variable_set(key, capabilities.presence)
        rescue Errno::ENOENT
          Thread.current.thread_variable_set(key, nil)
        end

        def path_identity(path)
          stat = path.lstat
          [ stat.dev, stat.ino, stat.ftype ]
        end

        def assert_active_record_semantics!(connection, expected_database, root, expected_identity: nil)
          identity = assert_active_record_target!(
            connection, expected_database, root, expected_identity:
          )
          raw_connection = connection.raw_connection
          if raw_connection.transaction_active?
            raise "Active Record SQLite database identity cannot be compared during a transaction"
          end

          canonical = Pathname(identity.fetch(:path))
          parent = canonical.dirname
          flags = File::RDONLY
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(canonical, flags) do |pinned|
            pinned_stat = pinned.stat
            unless pinned_stat.file? && pinned_stat.nlink == 1 &&
                [ pinned_stat.dev, pinned_stat.ino, pinned_stat.ftype ] == identity.fetch(:target_identity)
              raise "Active Record canonical SQLite database changed before semantic comparison"
            end

            checkpoint_sqlite_connection! raw_connection
            descriptor_path = if File.exist?("/proc/self/fd/#{pinned.fileno}")
              "/proc/self/fd/#{pinned.fileno}"
            else
              "/dev/fd/#{pinned.fileno}"
            end
            canonical_connection = SQLite3::Database.new(
              "file:#{descriptor_path}?immutable=1", uri: true, readonly: true
            )
            actual_digest = sqlite_snapshot_digest(raw_connection)
            canonical_digest = sqlite_snapshot_digest(canonical_connection)
            unless actual_digest == canonical_digest
              raise "Active Record SQLite connection does not semantically match the guarded Campfire database"
            end

            current = canonical.lstat
            unless path_identity(parent) == identity.fetch(:parent_identity) && current.file? &&
                current.nlink == 1 &&
                [ current.dev, current.ino, current.ftype ] == identity.fetch(:target_identity)
              raise "Active Record canonical SQLite database changed during semantic comparison"
            end
          ensure
            canonical_connection&.close
          end

          assert_active_record_target!(
            connection, expected_database, root, expected_identity: identity
          )
        rescue Errno::ENOENT, NoMethodError, TypeError, ArgumentError
          raise "Active Record SQLite database semantics cannot be verified"
        end

        def checkpoint_sqlite_connection!(database)
          result = database.get_first_row("PRAGMA wal_checkpoint(TRUNCATE)")
          result = result.values_at("busy", "log", "checkpointed") if result.is_a?(Hash)
          unless [ [ 0, 0, 0 ], [ 0, -1, -1 ] ].include?(result&.map(&:to_i))
            raise "Active Record SQLite WAL checkpoint did not complete"
          end
        end

        def sqlite_snapshot_digest(source)
          Dir.mktmpdir("campfire-database-identity") do |directory|
            path = Pathname(directory).join("snapshot.sqlite3")
            destination = SQLite3::Database.new(path.to_s)
            backup = SQLite3::Backup.new(destination, "main", source, "main")
            result = backup.step(-1)
            unless result == SQLite3::Constants::ErrorCode::DONE && backup.remaining.zero?
              raise "Active Record SQLite database identity snapshot did not complete"
            end
            backup.finish
            backup = nil
            mode = destination.get_first_value("PRAGMA journal_mode = DELETE")
            raise "Active Record SQLite identity snapshot retained WAL state" unless mode.to_s.downcase == "delete"
            destination.close
            destination = nil
            Digest::SHA256.file(path).hexdigest
          ensure
            begin
              backup&.finish
            rescue SQLite3::Exception
              nil
            end
            destination&.close
          end
        end

        def assert_active_record_target!(connection, expected_database, root, expected_identity: nil)
          actual = active_record_target(connection, root)
          expected_database = Pathname(expected_database).expand_path(root)
          unless !actual.symlink? && canonical_database_path(actual) == canonical_database_path(expected_database)
            raise "Active Record production database does not match the guarded Campfire database"
          end


          raw_connection = connection.raw_connection
          assert_sqlite_main_file_current!(raw_connection)
          identity = raw_connection.instance_variable_get(SQLITE_CONNECTION_IDENTITY_IVAR)
          parent = actual.dirname.realpath
          canonical = parent.join(actual.basename)
          target_stat = canonical.lstat
          opened_filename = canonical_database_path(raw_connection.filename("main"))
          descriptor = identity&.fetch(:descriptor, nil)
          descriptor_metadata = sqlite_descriptor_metadata(descriptor) if descriptor
          current_identity = {
            path: canonical.to_s,
            parent_identity: path_identity(parent),
            target_identity: [ target_stat.dev, target_stat.ino, target_stat.ftype ],
            descriptor:,
            descriptor_identity: descriptor_metadata&.fetch(:identity),
            pid: Process.pid
          }
          expected_matches = !expected_identity || same_database_identity?(identity, expected_identity)
          unless target_stat.file? && target_stat.nlink == 1 && opened_filename == canonical &&
              identity == current_identity && expected_matches
            raise "Active Record open database inode does not match the guarded Campfire database"
          end
          identity
        rescue Errno::ENOENT, NoMethodError, TypeError, ArgumentError
          raise "Active Record open database inode cannot be verified"
        end

        def same_database_identity?(left, right)
          %i[ path parent_identity target_identity descriptor_identity pid ].all? do |key|
            left&.fetch(key, nil) == right&.fetch(key, nil)
          end
        end
    end

    def initialize(storage_directory:, database_path:, environment:, build_identity: nil,
        revision: nil, authentication_key:, authentication_environment: ENV, now: Time.now.utc,
        encryption_keyring: nil, encryption_environment: authentication_environment,
        mount_identity_resolver: CampfireBackup::MountIdentity.method(:for_path),
        root: Pathname(File.expand_path("../..", __dir__)))
      @storage_directory = Pathname(storage_directory).expand_path
      @database_path = Pathname(database_path).expand_path
      @environment = environment
      build_identity ||= {
        "format_version" => 1,
        "revision" => revision.to_s,
        "build_identity" => Digest::SHA256.hexdigest("test-build\0#{revision}")
      }
      @build_identity = build_identity.transform_keys(&:to_s).freeze
      @authentication_key = authentication_key
      @authentication_environment = authentication_environment
      @encryption_keyring = encryption_keyring
      @encryption_environment = encryption_environment
      @mount_identity_resolver = mount_identity_resolver
      @owned_encryption_keyring = false
      @now = now.utc
      @root = Pathname(root).expand_path
    end

    def authorize!(archive_path:, authentication_path:)
      raise "Upgrade authorization is available only in production" unless production?
      raise "The legacy database does not require the gated migration" unless legacy_upgrade_required?

      key = authentication_key
      archive_path = external_recovery_path!(archive_path, "archive")
      authentication_path = external_recovery_path!(authentication_path, "authentication statement")
      fingerprint = installation_fingerprint
      manifest, source_manifest_sha256 = verified_recovery_manifest!(
        archive_path:, authentication_path:, fingerprint:, key:, full_validation: true
      )
      backup_id = manifest.fetch("backup_id")
      source_state_sha256 = SourceStateInventory.validate_manifest!(manifest)
      validate_live_source_state! manifest.fetch("source_state"), backup_id: backup_id
      verify_legacy_blob_inventory!

      receipt = Authentication.sign_statement({
        format_version: 2,
        kind: "campfire-upgrade-recovery",
        migration: GATED_MIGRATION,
        environment:,
        target_revision: build_identity.fetch("revision"),
        target_build_identity: build_identity.fetch("build_identity"),
        backup_id:,
        installation_fingerprint: fingerprint,
        source_schema_version: current_schema_version,
        source_state_sha256:,
        source_manifest_sha256:,
        archive_path: archive_path.to_s,
        archive_bytes: archive_path.size,
        archive_sha256: Digest::SHA256.file(archive_path).hexdigest,
        authentication_path: authentication_path.to_s,
        authentication_sha256: Digest::SHA256.file(authentication_path).hexdigest,
        created_at: now.iso8601,
        expires_at: (now + RECEIPT_LIFETIME).iso8601
      }, key:)
      write_receipt receipt

      puts JSON.generate(
        status: "upgrade_authorized", receipt: receipt_path.to_s, backup_id:,
        installation_fingerprint: fingerprint,
        target_build_identity: build_identity.fetch("build_identity"),
        expires_at: receipt.fetch(:expires_at)
      )
      true
    rescue JSON::ParserError, KeyError => error
      raise "Upgrade recovery evidence is invalid: #{error.message}"
    ensure
      clear_owned_encryption_keyring!
    end

    def verify_before_prepare!(connection: nil, full_archive_validation: true)
      if [
        BackupEncryption::KEY_ENVIRONMENT_VARIABLE,
        BackupEncryption::PREVIOUS_KEYS_ENVIRONMENT_VARIABLE
      ].any? { @encryption_environment.key?(_1) }
        encryption_keyring
      end
      return :not_production unless production?
      return :fresh unless database_path.file?
      return :fresh if fresh_database?(connection:)
      if migration_applied?(connection:)
        remove_completed_receipt!
        return :current
      end

      unless receipt_path.file? && !receipt_path.symlink?
        raise "Legacy schema #{current_schema_version(connection:)} requires authenticated recovery evidence before migration. " \
          "Run this target image with `bin/boot authorize-upgrade ARCHIVE AUTHENTICATION_STATEMENT`, then retry boot."
      end

      key = authentication_key
      receipt = JSON.parse(receipt_path.read)
      evidence = Authentication.verify_statement!(receipt, key:)
      validate_receipt! evidence, key, connection:, full_archive_validation:
      verify_legacy_blob_inventory!(connection:)
      @authorized = true
      :authorized
    rescue JSON::ParserError, KeyError, ArgumentError => error
      raise "Upgrade recovery receipt is invalid: #{error.message}"
    ensure
      clear_owned_encryption_keyring!
    end

    def complete!
      return unless @authorized
      raise "Database preparation did not apply gated migration #{GATED_MIGRATION}" unless migration_applied?

      FileUtils.rm_f receipt_path
      flush_directory storage_directory
    end

    private
      attr_reader :storage_directory, :database_path, :environment, :build_identity, :now, :root

      def production?
        environment == "production"
      end

      def authentication_key
        @authentication_key || Authentication.key_from_env(@authentication_environment)
      end

      def encryption_keyring
        @encryption_keyring ||= begin
          @owned_encryption_keyring = true
          keyring = BackupEncryption.keyring_from_env!(@encryption_environment)
          @encryption_keyring = keyring
          keyring.assert_distinct_from! authentication_key
          keyring
        end
      end

      def clear_owned_encryption_keyring!
        return unless @owned_encryption_keyring

        @encryption_keyring&.clear!
        @encryption_keyring = nil
        @owned_encryption_keyring = false
      end

      def receipt_path
        storage_directory.join(RECEIPT_FILENAME)
      end

      def remove_completed_receipt!
        return unless receipt_path.exist? || receipt_path.symlink?
        raise "Upgrade recovery receipt path is not a regular file" unless receipt_path.file? || receipt_path.symlink?

        FileUtils.rm_f receipt_path
        flush_directory storage_directory
      end

      def legacy_upgrade_required?
        database_path.file? && !fresh_database? && !migration_applied?
      end

      def fresh_database?(connection: nil)
        with_database(connection:) do |database|
          tables = first_column_values(database, "SELECT name FROM sqlite_schema WHERE type = 'table'")
          relevant = FRESHNESS_TABLES & tables
          return true if relevant.empty? && !tables.include?("schema_migrations")
          return false unless relevant == FRESHNESS_TABLES

          shadow_tables = database.execute("PRAGMA table_list").filter_map do |row|
            schema, name, type = if row.is_a?(Hash)
              row.values_at("schema", "name", "type")
            else
              row.values_at(0, 1, 2)
            end
            name if schema == "main" && type == "shadow"
          end
          durable_tables = tables.reject do |table|
            table.in?(FRESHNESS_INTERNAL_TABLES) ||
              table.in?(shadow_tables)
          end
          durable_tables.all? do |table|
            database.get_first_value("SELECT COUNT(*) FROM #{quote_identifier(table)}").to_i.zero?
          end
        end
      end

      def migration_applied?(connection: nil)
        schema_versions(connection:).include?(GATED_MIGRATION)
      end

      def current_schema_version(connection: nil)
        schema_versions(connection:).max || raise("Database has no applied schema migrations")
      end

      def schema_versions(connection: nil)
        with_database(connection:) do |database|
          unless database.table_info("schema_migrations").any?
            raise "Existing database does not contain schema_migrations"
          end

          first_column_values(database, "SELECT version FROM schema_migrations").map { Integer(_1.to_s, 10) }
        end
      end

      def first_column_values(database, sql)
        database.execute(sql).map do |row|
          row.is_a?(Hash) ? row.values.first : Array(row).first
        end
      end

      def with_database(connection: nil)
        database = connection&.raw_connection || connection
        if database
          yield database
        else
          database = SQLite3::Database.new(database_path.to_s, readonly: true)
          yield database
        end
      ensure
        database&.close unless connection
      end

      def verify_legacy_blob_inventory!(connection: nil)
        with_database(connection:) do |database|
          tables = first_column_values(database, "SELECT name FROM sqlite_schema WHERE type = 'table'")
          required = %w[ active_storage_blobs active_storage_attachments ]
          return true unless (required - tables).empty?

          unattached_count = database.get_first_value(<<~SQL).to_i
            SELECT COUNT(*)
            FROM active_storage_blobs blobs
            WHERE NOT EXISTS (
              SELECT 1 FROM active_storage_attachments attachments
              WHERE attachments.blob_id = blobs.id
            )
          SQL
          blob_keys = first_column_values(database, "SELECT key FROM active_storage_blobs").to_h do |key|
            [ key.to_s, true ]
          end
          untracked_file_count = legacy_storage_keys.count do |key|
            !blob_keys.key?(key) && !tracked_legacy_variant?(key, blob_keys)
          end
          return true if unattached_count.zero? && untracked_file_count.zero?

          raise "Legacy Active Storage contains #{unattached_count} unattached blob(s) and " \
            "#{untracked_file_count} untracked file(s), so banned-content ownership cannot be proven. " \
            "Resume the exact legacy image and drain or inventory all legacy purge work until no " \
            "unattached blobs or untracked files remain before authorizing this upgrade."
        end
      end

      def legacy_storage_keys
        root = storage_directory.join("files")
        return [] unless root.exist?

        Dir.glob(root.join("**", "*"), File::FNM_DOTMATCH).filter_map do |name|
          path = Pathname(name)
          next if %w[ . .. ].include?(path.basename.to_s) || path.directory?

          relative = path.relative_path_from(root).each_filename.to_a
          next "" unless relative.size >= 3

          key = relative.drop(2).join("/")
          relative.first == key[0, 2] && relative[1] == key[2, 2] ? key : ""
        end
      end

      def tracked_legacy_variant?(key, blob_keys)
        prefix, source_key, derivative = key.split("/", 3)
        prefix == "variants" && !source_key.to_s.empty? && !derivative.to_s.empty? &&
          blob_keys.key?(source_key)
      end

      def installation_identifier
        InstallationIdentity.read!(storage_directory.join(InstallationIdentity::FILENAME))
      rescue Errno::ENOENT
        raise "The installation marker is missing; create and archive the pre-upgrade backup before authorization"
      end

      def installation_fingerprint
        InstallationIdentity.fingerprint(installation_identifier)
      end

      def external_recovery_path!(path, description)
        path = Pathname(path).expand_path
        stat = path.lstat
        unless stat.file? && !stat.symlink? && stat.nlink == 1
          raise "Upgrade recovery #{description} must be an independent regular file"
        end

        path = path.realpath
        storage = storage_directory.realpath
        if path == storage || path.to_s.start_with?("#{storage}/")
          raise "Upgrade recovery #{description} must be stored outside the Campfire volume"
        end

        storage_mount = @mount_identity_resolver.call(storage)
        recovery_mount = @mount_identity_resolver.call(path)
        unless [ [ storage_mount, storage ], [ recovery_mount, path ] ].all? do |mount, candidate|
          mount.is_a?(CampfireBackup::MountIdentity::Entry) && mount.covers?(candidate)
        end
          raise "Upgrade recovery mount identity could not be verified"
        end
        if storage_mount.same_source_volume?(recovery_mount)
          raise "Upgrade recovery #{description} must be stored outside the Campfire volume"
        end

        path
      rescue Errno::ENOENT
        raise "Upgrade recovery #{description} does not exist"
      rescue CampfireBackup::MountIdentity::Error => error
        raise "Upgrade recovery mount identity could not be verified: #{error.message}"
      end

      def verified_recovery_manifest!(archive_path:, authentication_path:, fingerprint:, key:,
          full_validation:, expected_backup_id: nil)
        # Authorization and boot verify the encrypted payload in full. The migration
        # boundary reuses only the HMAC receipt that pins those exact envelope bytes.
        if Thread.current.thread_variable_get(MIGRATION_OPERATION_KEY)
          full_validation = false
        end
        if encrypted_recovery_envelope?(archive_path, authentication_path)
          backup_id = expected_backup_id || latest_backup_id!
          source_manifest, source_manifest_sha256 = source_generation_manifest!(
            backup_id, fingerprint:, key:, full_validation:
          )
          if full_validation
            extracted_manifest, archive_evidence = extracted_encrypted_archive_manifest!(
              archive_path:, backup_id:, fingerprint:, key:
            )
            validate_archive_evidence! archive_evidence, fingerprint
            unless Digest::SHA256.hexdigest(extracted_manifest) == source_manifest_sha256
              raise "Upgrade archive does not contain the exact current backup generation"
            end

            manifest = JSON.parse(source_manifest)
            source_state_sha256 = SourceStateInventory.validate_manifest!(manifest)
            unless secure_compare(source_state_sha256, archive_evidence.fetch("source_state_sha256"))
              raise "Upgrade archive source-state authentication does not match"
            end
          end
          return [ JSON.parse(source_manifest), source_manifest_sha256 ]
        end

        authentication_data = BackupEncryption.read_independent_file(
          authentication_path, description: "Legacy backup authentication statement",
          maximum_bytes: BackupEncryption::MAX_AUTHENTICATION_BYTES
        )
        statement = JSON.parse(authentication_data)
        archive_evidence = Authentication.verify_statement!(statement, key:)
        backup_id = archive_evidence.fetch("backup_id")
        validate_archive_evidence! archive_evidence, fingerprint
        BackupEncryption.open_independent_file(
          archive_path, description: "Legacy plaintext backup archive",
          maximum_bytes: BackupEncryption::MAX_ARCHIVE_BYTES
        ) do |archive_io|
          Authentication.verify_archive!(
            archive_io:, authentication_data:, expected_backup_id: backup_id,
            expected_installation_fingerprint: fingerprint, expected_environment: environment, key:,
            expected_archive_filename: "campfire-#{backup_id}.tar.gz"
          )
        end

        source_manifest, source_manifest_sha256 = source_generation_manifest!(
          backup_id, fingerprint:, key:, full_validation:
        )
        if full_validation
          extracted_manifest = extracted_archive_manifest!(
            archive_path:, authentication_path:, backup_id:, fingerprint:, key:
          )
          unless Digest::SHA256.hexdigest(extracted_manifest) == source_manifest_sha256
            raise "Upgrade archive does not contain the exact current backup generation"
          end
        end

        manifest = JSON.parse(source_manifest)
        source_state_sha256 = SourceStateInventory.validate_manifest!(manifest)
        unless secure_compare(source_state_sha256, archive_evidence.fetch("source_state_sha256"))
          raise "Upgrade archive source-state authentication does not match"
        end
        [ manifest, source_manifest_sha256 ]
      end

      def encrypted_recovery_envelope?(archive_path, authentication_path)
        return false unless archive_path == authentication_path

        encrypted = BackupEncryption.open_independent_file(
          archive_path, description: "Upgrade recovery artifact",
          maximum_bytes: BackupEncryption::HEADER_BYTES + BackupEncryption::MAX_KEY_ID_BYTES +
            BackupEncryption::NONCE_BYTES + BackupEncryption::MAX_PAYLOAD_BYTES + BackupEncryption::TAG_BYTES
        ) do |file|
          file.read(BackupEncryption::MAGIC.bytesize) == BackupEncryption::MAGIC
        end
        raise "A single-file upgrade recovery artifact must use the encrypted backup format" unless encrypted

        true
      end

      def latest_backup_id!
        latest = storage_directory.join("backups/latest")
        unless latest.symlink?
          raise "Upgrade recovery requires the latest encrypted backup generation"
        end

        latest.realpath.basename.to_s
      rescue Errno::ENOENT
        raise "Upgrade recovery requires the latest encrypted backup generation"
      end

      def source_generation_manifest!(backup_id, fingerprint:, key:, full_validation:)
        generation = storage_directory.join("backups", backup_id)
        latest = storage_directory.join("backups", "latest")
        unless generation.directory? && !generation.symlink? && latest.symlink? && latest.realpath == generation.realpath
          raise "Upgrade archive is not the latest backup generation from the stopped source"
        end

        load_backup_verifier! if full_validation
        if full_validation
          BackupVerifier.verify(
            generation_path: generation, expected_installation_fingerprint: fingerprint,
            expected_environment: environment, authentication_key: key, output: false
          )
        end
        manifest_path = generation.join("manifest.json")
        raise "Upgrade source generation manifest is invalid" unless manifest_path.file? && !manifest_path.symlink?
        source = manifest_path.read
        manifest = JSON.parse(source)
        Authentication.verify_manifest!(manifest, key:)
        [ source, Digest::SHA256.hexdigest(source) ]
      end

      def extracted_archive_manifest!(archive_path:, authentication_path:, backup_id:, fingerprint:, key:)
        load_backup_extractor!
        load_backup_verifier!
        Dir.mktmpdir("campfire-upgrade-recovery") do |directory|
          generation = BackupExtractor.extract(
            archive_path:, destination_directory: Pathname(directory).join("extracted"), backup_id:,
            legacy_authentication_path: authentication_path,
            expected_installation_fingerprint: fingerprint,
            expected_environment: environment, authentication_key: key, output: false
          )
          BackupVerifier.verify(
            generation_path: generation, expected_installation_fingerprint: fingerprint,
            expected_environment: environment, authentication_key: key, output: false
          )
          generation.join("manifest.json").read
        end
      end

      def extracted_encrypted_archive_manifest!(archive_path:, backup_id:, fingerprint:, key:)
        load_backup_extractor!
        load_backup_verifier!
        archive_evidence = nil
        extracted_manifest = nil
        Dir.mktmpdir("campfire-upgrade-recovery") do |directory|
          File.chmod 0o700, directory
          generation = BackupExtractor.extract(
            archive_path:, destination_directory: Pathname(directory).join("extracted"), backup_id:,
            expected_installation_fingerprint: fingerprint, expected_environment: environment,
            authentication_key: key, encryption_keyring:, output: false
          ) { archive_evidence = _1 }
          BackupVerifier.verify(
            generation_path: generation, expected_installation_fingerprint: fingerprint,
            expected_environment: environment, authentication_key: key, output: false
          )
          extracted_manifest = generation.join("manifest.json").read
        end
        [ extracted_manifest, archive_evidence ]
      end

      def load_backup_extractor!
        load root.join("script/admin/extract-backup") unless defined?(BackupExtractor)
      end

      def load_backup_verifier!
        load root.join("script/admin/verify-backup") unless defined?(BackupVerifier)
      end

      def validate_archive_evidence!(evidence, fingerprint)
        unless evidence.fetch("format_version") == Authentication::ARCHIVE_FORMAT_VERSION &&
            evidence.fetch("kind") == "campfire-backup-archive" &&
            evidence.fetch("environment") == environment &&
            evidence.fetch("installation_fingerprint") == fingerprint &&
            evidence.fetch("schema_version") == current_schema_version &&
            evidence.fetch("source_state_sha256").match?(/\A[0-9a-f]{64}\z/)
          raise "Upgrade archive does not match the stopped legacy installation"
        end
      end

      def validate_receipt!(evidence, key, connection:, full_archive_validation:)
        unless evidence.fetch("format_version") == 2 &&
            evidence.fetch("kind") == "campfire-upgrade-recovery" &&
            evidence.fetch("migration") == GATED_MIGRATION &&
            evidence.fetch("environment") == environment &&
            evidence.fetch("target_revision") == build_identity.fetch("revision") &&
            evidence.fetch("target_build_identity") == build_identity.fetch("build_identity") &&
            evidence.fetch("source_schema_version") == current_schema_version(connection:) &&
            secure_compare(evidence.fetch("installation_fingerprint"), installation_fingerprint)
          raise "receipt target, schema, environment, or installation does not match"
        end

        created_at = Time.iso8601(evidence.fetch("created_at"))
        expires_at = Time.iso8601(evidence.fetch("expires_at"))
        unless created_at <= now + 5 * 60 && expires_at > now && expires_at <= created_at + RECEIPT_LIFETIME
          raise "receipt is stale or has an invalid lifetime"
        end

        archive_path = external_recovery_path!(evidence.fetch("archive_path"), "archive")
        authentication_path = external_recovery_path!(
          evidence.fetch("authentication_path"), "authentication statement"
        )
        unless archive_path.size == evidence.fetch("archive_bytes") &&
            secure_compare(Digest::SHA256.file(archive_path).hexdigest, evidence.fetch("archive_sha256")) &&
            secure_compare(Digest::SHA256.file(authentication_path).hexdigest, evidence.fetch("authentication_sha256"))
          raise "recovery archive bytes changed after authorization"
        end

        manifest, source_manifest_sha256 = verified_recovery_manifest!(
          archive_path:, authentication_path:, fingerprint: evidence.fetch("installation_fingerprint"),
          key:, full_validation: full_archive_validation,
          expected_backup_id: evidence.fetch("backup_id")
        )
        unless secure_compare(source_manifest_sha256, evidence.fetch("source_manifest_sha256")) &&
            secure_compare(SourceStateInventory.digest(manifest.fetch("source_state")), evidence.fetch("source_state_sha256"))
          raise "recovery source-state evidence changed after authorization"
        end
        validate_live_source_state! manifest.fetch("source_state"), backup_id: evidence.fetch("backup_id"), connection:
      end

      def validate_live_source_state!(expected, backup_id:, connection: nil)
        actual = SourceStateInventory.capture(
          database: connection&.raw_connection || connection || database_path,
          database_path:, storage_directory:, environment:, backup_id:,
          installation_identifier:, schema_version: current_schema_version(connection:)
        )
        unless secure_compare(SourceStateInventory.digest(actual), SourceStateInventory.digest(expected)) && actual == expected
          raise "Upgrade archive does not contain the complete current stopped source state: #{inventory_difference(expected, actual)}"
        end
      end

      def inventory_difference(expected, actual, path = "source_state")
        if expected.is_a?(Hash) && actual.is_a?(Hash)
          keys = (expected.keys | actual.keys).sort
          key = keys.find { expected[_1] != actual[_1] }
          return inventory_difference(expected[key], actual[key], "#{path}.#{key}") if key
        elsif expected.is_a?(Array) && actual.is_a?(Array)
          index = [ expected.length, actual.length ].max.times.find { expected[_1] != actual[_1] }
          return inventory_difference(expected[index], actual[index], "#{path}[#{index}]") if index
        end

        "#{path} differs"
      end

      def write_receipt(receipt)
        storage_directory.mkpath
        temporary = storage_directory.join(".#{RECEIPT_FILENAME}.#{SecureRandom.hex(8)}.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write JSON.pretty_generate(receipt) << "\n"
          file.fsync
        end
        File.rename temporary, receipt_path
        flush_directory storage_directory
      ensure
        FileUtils.rm_f temporary if defined?(temporary)
      end

      def flush_directory(path)
        File.open(path, &:fsync)
      end

      def secure_compare(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        result = 0
        left.bytes.zip(right.bytes) { |a, b| result |= a ^ b }
        result.zero?
      end

      def quote_identifier(value)
        %Q("#{value.to_s.gsub('"', '""')}")
      end
  end
end
