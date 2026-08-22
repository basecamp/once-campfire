require "digest"
require "json"
require "pathname"
require "sqlite3"
require "tmpdir"
require_relative "installation_identity"

module CampfireBackup
  module SourceStateInventory
    FORMAT_VERSION = 1
    PERSISTENT_DIRECTORIES = %w[ files redis ].freeze
    DATABASE_SIDECARS = %w[ -wal -shm -journal ].freeze

    class << self
      def capture(database:, database_path:, storage_directory:, environment:, backup_id:,
          installation_identifier:, schema_version:, database_relative_path: nil)
        database_path = Pathname(database_path).expand_path
        storage_directory = Pathname(storage_directory).expand_path
        if storage_directory.symlink? || !storage_directory.directory?
          raise "Campfire storage inventory root is not an independent directory"
        end
        database_stat = database_path.lstat
        unless database_stat.file? && !database_path.symlink? && database_stat.nlink == 1 &&
            !database_path.dirname.symlink?
          raise "Campfire database inventory source is not an independent regular file"
        end
        relative_database = database_relative_path || database_path.relative_path_from(storage_directory).to_s
        if database_relative_path.nil? && relative_database.start_with?("../")
          raise "Campfire database must be inside the storage directory"
        end
        relative_database = Pathname(relative_database).cleanpath.to_s
        if Pathname(relative_database).absolute? || relative_database.start_with?("../")
          raise "Campfire database inventory path is invalid"
        end

        {
          "format_version" => FORMAT_VERSION,
          "backup_id" => backup_id,
          "environment" => environment,
          "installation_fingerprint" => InstallationIdentity.fingerprint(installation_identifier),
          "schema_version" => Integer(schema_version),
          "database" => canonical_database_metadata(database, relative_database),
          "database_sidecars" => database_sidecars(database_path, relative_database),
          "storage_files" => storage_files(storage_directory)
        }
      end

      def digest(inventory)
        Digest::SHA256.hexdigest JSON.generate(canonicalize(inventory))
      end

      def validate_manifest!(manifest)
        inventory = manifest.fetch("source_state")
        unless inventory.keys.sort == %w[
            backup_id database database_sidecars environment format_version
            installation_fingerprint schema_version storage_files
          ]
          raise "Backup source-state inventory is invalid"
        end
        unless inventory.fetch("format_version") == FORMAT_VERSION &&
            inventory.fetch("backup_id") == manifest.fetch("backup_id") &&
            inventory.fetch("environment") == manifest.fetch("environment") &&
            inventory.fetch("installation_fingerprint") == manifest.fetch("installation_fingerprint") &&
            inventory.fetch("schema_version") == manifest.fetch("schema_version")
          raise "Backup source-state identity does not match its manifest"
        end

        database = inventory.fetch("database")
        manifest_database = manifest.fetch("database")
        database_path = safe_relative_path(database.fetch("path"), "database")
        unless database.keys.sort == %w[ bytes path sha256 ] &&
            database_path.basename.to_s == manifest_database.fetch("path") &&
            database.fetch("bytes") == manifest_database.fetch("bytes") &&
            database.fetch("sha256") == manifest_database.fetch("sha256")
          raise "Backup source-state database does not match its snapshot"
        end
        unless inventory.fetch("database_sidecars") == expected_database_sidecars(database_path.to_s)
          raise "Backup source-state database sidecar contract is invalid"
        end
        unless inventory.fetch("storage_files") == manifest.fetch("files").sort_by { _1.fetch("path") }
          raise "Backup source-state files do not match its payload"
        end

        digest inventory
      rescue KeyError, NoMethodError, ArgumentError, TypeError
        raise "Backup source-state inventory is invalid"
      end

      private
        def canonical_database_metadata(source, relative_path)
          source = source.raw_connection if source.respond_to?(:raw_connection)
          close_source = false
          unless source.is_a?(SQLite3::Database)
            source = SQLite3::Database.new(source.to_s, readonly: true)
            close_source = true
          end

          Dir.mktmpdir("campfire-source-state") do |directory|
            path = Pathname(directory).join("canonical.sqlite3")
            destination = SQLite3::Database.new(path.to_s)
            backup = SQLite3::Backup.new(destination, "main", source, "main")
            backup.step(-1)
            backup.finish
            backup = nil
            mode = destination.get_first_value("PRAGMA journal_mode = DELETE")
            raise "Source-state snapshot could not disable WAL sidecars" unless mode.to_s.downcase == "delete"
            unless destination.get_first_value("PRAGMA integrity_check") == "ok" &&
                destination.execute("PRAGMA foreign_key_check").empty?
              raise "Source-state database validation failed"
            end
            destination.close
            destination = nil

            {
              "path" => relative_path,
              "bytes" => path.size,
              "sha256" => Digest::SHA256.file(path).hexdigest
            }
          ensure
            begin
              backup&.finish
            rescue SQLite3::Exception
              nil
            end
            destination&.close
          end
        ensure
          source&.close if close_source
        end

        def database_sidecars(database_path, relative_database)
          paths = DATABASE_SIDECARS.to_h do |suffix|
            path = Pathname("#{database_path}#{suffix}")
            if path.exist? || path.symlink?
              raise "Campfire database sidecar is not a regular file" unless path.file? && !path.symlink?
            end
            [ suffix, path ]
          end
          if paths.fetch("-journal").exist?
            raise "Campfire database has an unexpected rollback journal"
          end
          if paths.fetch("-wal").exist? && !paths.fetch("-wal").zero?
            raise "Campfire database WAL contains uncheckpointed bytes"
          end

          expected_database_sidecars relative_database
        end

        def storage_files(storage_directory)
          entries = PERSISTENT_DIRECTORIES.flat_map do |directory|
            root = storage_directory.join(directory)
            next [] unless root.exist?
            raise "Campfire storage contains a symbolic link" if root.symlink?
            raise "Campfire storage path is not a directory" unless root.directory?

            Dir.glob(root.join("**", "*"), File::FNM_DOTMATCH).filter_map do |name|
              path = Pathname(name)
              next if %w[ . .. ].include?(path.basename.to_s)

              stat = path.lstat
              raise "Campfire storage contains a symbolic link or special file" if stat.symlink? || (!stat.file? && !stat.directory?)
              metadata(path, storage_directory) if stat.file?
            end
          end
          marker = storage_directory.join(InstallationIdentity::FILENAME)
          entries << metadata(marker, storage_directory) if marker.file? && !marker.symlink?
          entries.sort_by { _1.fetch("path") }
        end

        def metadata(path, root)
          {
            "path" => path.relative_path_from(root).to_s,
            "bytes" => path.size,
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        end

        def expected_database_sidecars(relative_database)
          [
            { "path" => "#{relative_database}-journal", "required_state" => "absent" },
            { "path" => "#{relative_database}-shm", "required_state" => "absent-or-regular-transient" },
            { "path" => "#{relative_database}-wal", "required_state" => "absent-or-empty" }
          ]
        end

        def safe_relative_path(value, description)
          path = Pathname(value).cleanpath
          if path.absolute? || path.to_s == "." || path.to_s.start_with?("../")
            raise "Backup source-state #{description} path is invalid"
          end
          path
        end

        def canonicalize(value)
          case value
          when Hash
            value.to_h { |key, item| [ key.to_s, canonicalize(item) ] }.sort.to_h
          when Array
            value.map { canonicalize(_1) }
          else
            value
          end
        end
    end
  end
end
