require "base64"
require "digest"
require "json"
require "openssl"
require "pathname"

module CampfireBackup
  module Authentication
    ALGORITHM = "HMAC-SHA256"
    ARCHIVE_FORMAT_VERSION = 1
    KEY_ENVIRONMENT_VARIABLE = "BACKUP_AUTHENTICATION_KEY"
    MINIMUM_KEY_BYTES = 32

    class << self
      def key_from_env(env = ENV)
        encoded = env[KEY_ENVIRONMENT_VARIABLE].to_s
        raise "#{KEY_ENVIRONMENT_VARIABLE} is required" if encoded.empty?

        Base64.strict_decode64(encoded).tap do |key|
          raise "#{KEY_ENVIRONMENT_VARIABLE} must contain at least 32 random bytes" if key.bytesize < MINIMUM_KEY_BYTES
        end
      rescue ArgumentError
        raise "#{KEY_ENVIRONMENT_VARIABLE} must be strict Base64"
      end

      def sign_manifest(manifest, key:)
        manifest.merge(authentication: authentication_for(manifest, key:))
      end

      def verify_manifest!(manifest, key:)
        authentication = manifest.fetch("authentication")
        payload = manifest.except("authentication")
        verify_authentication!(payload, authentication, key:)
        payload
      end

      def sign_statement(statement, key:)
        statement.merge(authentication: authentication_for(statement, key:))
      end

      def verify_statement!(statement, key:)
        authentication = statement.fetch("authentication")
        payload = statement.except("authentication")
        verify_authentication!(payload, authentication, key:)
        payload
      end

      def verify_archive!(archive_path: nil, archive_io: nil, authentication_path: nil,
          authentication_data: nil, expected_backup_id:,
          expected_installation_fingerprint:, expected_environment:, key:,
          expected_archive_filename: nil)
        if archive_io && archive_path
          raise "Backup archive verification accepts either a path or an open descriptor"
        elsif archive_io
          raise "Backup archive filename is required for descriptor verification" unless expected_archive_filename
          archive_size, archive_sha256 = archive_metadata(archive_io)
        else
          archive_path = Pathname(archive_path).realpath
          expected_archive_filename ||= archive_path.basename.to_s
          flags = File::RDONLY
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          flags |= File::NONBLOCK if defined?(File::NONBLOCK)
          File.open(archive_path, flags) do |file|
            archive_size, archive_sha256 = archive_metadata(file)
          end
        end

        if authentication_path && authentication_data
          raise "Backup archive verification accepts either authentication data or a path"
        elsif authentication_data
          statement = JSON.parse(authentication_data)
        elsif authentication_path
          statement = JSON.parse(Pathname(authentication_path).read)
        else
          raise "Backup archive authentication statement is required"
        end
        payload = verify_statement!(statement, key:)
        unless payload.fetch("format_version") == ARCHIVE_FORMAT_VERSION
          raise "Backup archive statement has an unsupported format version"
        end
        raise "Backup archive statement has an unsupported kind" unless payload.fetch("kind") == "campfire-backup-archive"
        raise "Backup archive ID does not match" unless payload.fetch("backup_id") == expected_backup_id
        unless secure_compare(payload.fetch("installation_fingerprint"), expected_installation_fingerprint)
          raise "Backup archive belongs to a different Campfire installation"
        end
        raise "Backup archive environment does not match" unless payload.fetch("environment") == expected_environment

        archive = payload.fetch("archive")
        unless archive.fetch("filename") == expected_archive_filename && archive.fetch("bytes") == archive_size
          raise "Backup archive metadata does not match"
        end
        unless secure_compare(archive.fetch("sha256"), archive_sha256)
          raise "Backup archive authentication does not match its bytes"
        end

        payload
      end

      def key_id(key)
        Digest::SHA256.hexdigest(key)[0, 16]
      end

      private
        def archive_metadata(file)
          stat = file.stat
          raise "Backup archive source is not a regular file" unless stat.file?

          position = file.pos
          file.binmode
          file.rewind
          digest = Digest::SHA256.new
          while (chunk = file.read(1024 * 1024))
            digest << chunk
          end
          unless file.stat.size == stat.size
            raise "Backup archive changed during authentication"
          end
          [ stat.size, digest.hexdigest ]
        ensure
          file.seek(position, IO::SEEK_SET) if defined?(position) && position
        end

        def authentication_for(payload, key:)
          {
            algorithm: ALGORITHM,
            key_id: key_id(key),
            mac: OpenSSL::HMAC.hexdigest("SHA256", key, canonical_json(payload))
          }
        end

        def verify_authentication!(payload, authentication, key:)
          unless authentication.fetch("algorithm") == ALGORITHM &&
              secure_compare(authentication.fetch("key_id"), key_id(key))
            raise "Backup authentication key or algorithm does not match"
          end

          expected = OpenSSL::HMAC.hexdigest("SHA256", key, canonical_json(payload))
          raise "Backup authentication failed" unless secure_compare(authentication.fetch("mac"), expected)
        rescue KeyError, NoMethodError
          raise "Backup authentication metadata is invalid"
        end

        def canonical_json(value)
          JSON.generate(canonicalize(value))
        end

        def canonicalize(value)
          case value
          when Hash
            value.to_h { |key, item| [ key.to_s, canonicalize(item) ] }.sort.to_h
          when Array
            value.map { canonicalize(_1) }
          when String, Integer, Float, TrueClass, FalseClass, NilClass
            value
          else
            canonicalize(value.as_json)
          end
        end

        def secure_compare(left, right)
          left = left.to_s
          right = right.to_s
          return false unless left.bytesize == right.bytesize

          result = 0
          left.bytes.zip(right.bytes) { |a, b| result |= a ^ b }
          result.zero?
        end
    end
  end
end
