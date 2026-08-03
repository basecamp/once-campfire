require "digest"
require "fileutils"
require "pathname"
require "securerandom"

module CampfireBackup
  module InstallationIdentity
    FILENAME = "installation-identifier"
    PATTERN = /\A[0-9a-f]{32}\z/

    class << self
      def ensure!(storage_directory, database)
        storage_directory = Pathname(storage_directory)
        marker = storage_directory.join(FILENAME)
        database_identifier = identifier_from_database(database)
        validate_marker_path! marker if marker.exist? || marker.symlink?
        marker_identifier = marker.read.strip if marker.file?
        validate! marker_identifier if marker_identifier

        identifier = database_identifier || marker_identifier || generate
        if database_identifier && marker_identifier && database_identifier != marker_identifier
          raise "Installation identity marker does not match the database"
        end
        write_marker marker, identifier unless marker_identifier
        ensure_marker_permissions marker
        identifier
      end

      def generate
        SecureRandom.hex(16)
      end

      def valid?(identifier)
        identifier.is_a?(String) && identifier.match?(PATTERN)
      end

      def fingerprint(identifier)
        validate! identifier
        Digest::SHA256.hexdigest(identifier)
      end

      def read!(path)
        path = Pathname(path)
        validate_marker_path! path
        path.read.strip.tap { validate!(_1) }
      end

      def validate!(identifier)
        raise "Installation identity is invalid" unless valid?(identifier)
      end

      private
        def validate_marker_path!(path)
          stat = path.lstat
          unless stat.file? && !path.symlink? && stat.nlink == 1
            raise "Installation identity marker is not an independent regular file"
          end
        end

        def identifier_from_database(database)
          count = database.get_first_value("SELECT COUNT(*) FROM accounts").to_i
          raise "Backup requires exactly one initialized Campfire account" unless count == 1
          return unless database.execute("PRAGMA table_info(accounts)").any? do |row|
            (row.is_a?(Hash) ? row["name"] : row[1]) == "installation_identifier"
          end

          database.get_first_value("SELECT installation_identifier FROM accounts").to_s.tap { validate!(_1) }
        end

        def write_marker(path, identifier)
          path.dirname.mkpath
          temporary = path.dirname.join(".#{path.basename}.#{SecureRandom.hex(8)}.tmp")
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
            file.write "#{identifier}\n"
            file.fsync
          end
          File.rename temporary, path
          File.open(path.dirname, &:fsync)
        ensure
          FileUtils.rm_f temporary if defined?(temporary)
        end

        def ensure_marker_permissions(path)
          return if (path.stat.mode & 0o777) == 0o644

          File.chmod 0o644, path
          File.open(path, "rb", &:fsync)
          File.open(path.dirname, &:fsync)
        end
    end
  end
end
