require "base64"
require "json"
require "openssl"
require "pathname"
require "securerandom"
require_relative "subprocess"

module CampfireBackup
  module BackupEncryption
    KEY_ENVIRONMENT_VARIABLE = "BACKUP_ENCRYPTION_KEY"
    KEY_ID_ENVIRONMENT_VARIABLE = "BACKUP_ENCRYPTION_KEY_ID"
    PREVIOUS_KEYS_ENVIRONMENT_VARIABLE = "BACKUP_ENCRYPTION_PREVIOUS_KEYS"

    MAGIC = "CFBKENC\0".b.freeze
    FORMAT_VERSION = 1
    CIPHER_AES_256_GCM = 1
    FLAGS = 0
    KEY_BYTES = 32
    NONCE_BYTES = 12
    TAG_BYTES = 16
    MAX_KEY_ID_BYTES = 64
    MAX_PREVIOUS_KEYS = 32
    MAX_KEYRING_JSON_BYTES = 32 * 1024
    MAX_AUTHENTICATION_BYTES = 1024 * 1024
    GCM_MAX_PLAINTEXT_BYTES = (1 << 36) - 32
    MAX_PAYLOAD_BYTES = 32 * 1024 * 1024 * 1024
    CHUNK_BYTES = 1024 * 1024
    STAGING_RESERVE_BYTES = 16 * 1024 * 1024

    HEADER_PACK = "a8CCnnCCQ>"
    HEADER_BYTES = 24
    BUNDLE_MAGIC = "CFBKARC\0".b.freeze
    BUNDLE_FORMAT_VERSION = 1
    BUNDLE_KIND_ARCHIVE = 1
    BUNDLE_HEADER_PACK = "a8CCnNQ>"
    BUNDLE_HEADER_BYTES = 24
    MIN_PAYLOAD_BYTES = BUNDLE_HEADER_BYTES + 2
    MAX_ARCHIVE_BYTES = MAX_PAYLOAD_BYTES - BUNDLE_HEADER_BYTES - 1
    KEY_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

    raise "Backup payload limit must remain below the AES-GCM plaintext limit" unless
      MAX_PAYLOAD_BYTES < GCM_MAX_PLAINTEXT_BYTES

    ArchiveStat = Struct.new(:size) do
      def file?
        true
      end

      def dev
        0
      end

      def ino
        0
      end

      def ftype
        "file"
      end
    end

    class ArchiveView
      def initialize(file, offset:, size:)
        @file = file
        @offset = offset
        @size = size
        @position = 0
      end

      def binmode
        self
      end

      def closed?
        @file.closed?
      end

      def eof?
        @position >= @size
      end

      def pos
        @position
      end
      alias tell pos

      def read(length = nil, output = nil)
        if length
          length = Integer(length)
          raise ArgumentError, "negative length" if length.negative?

          data = if length.zero?
            +"".b
          elsif eof?
            nil
          else
            @file.pread([ length, @size - @position ].min, @offset + @position).tap do |chunk|
              @position += chunk.bytesize
            end
          end
        else
          data = +"".b
          while (chunk = read(CHUNK_BYTES))
            data << chunk
          end
        end

        return data unless output

        output.replace(data || +"".b)
        data.nil? ? nil : output
      end

      def readpartial(length, output = nil)
        read(length, output) || raise(EOFError)
      end

      def rewind
        seek 0
        0
      end

      def seek(amount, whence = IO::SEEK_SET)
        amount = Integer(amount)
        position = case whence
        when IO::SEEK_SET then amount
        when IO::SEEK_CUR then @position + amount
        when IO::SEEK_END then @size + amount
        else raise Errno::EINVAL
        end
        raise Errno::EINVAL unless position.between?(0, @size)

        @position = position
        0
      end

      def stat
        ArchiveStat.new(@size)
      end
    end

    class Keyring
      attr_reader :active_id

      def initialize(active_id:, active_key:, previous_keys: {})
        @active_id = BackupEncryption.validate_key_id!(active_id)
        @keys = { @active_id => BackupEncryption.validate_key!(active_key).dup }
        raise "Too many previous backup encryption keys" if previous_keys.size > MAX_PREVIOUS_KEYS

        previous_keys.each do |key_id, key|
          key_id = BackupEncryption.validate_key_id!(key_id)
          raise "Duplicate backup encryption key ID: #{key_id}" if @keys.key?(key_id)

          @keys[key_id] = BackupEncryption.validate_key!(key).dup
        end
      end

      def active_key
        key_for(active_id)
      end

      def key_for(key_id)
        @keys.fetch(key_id) do
          raise "Backup encryption key ID is not available: #{key_id}"
        end
      end

      def key_ids
        @keys.keys.dup.freeze
      end

      def assert_distinct_from!(authentication_key)
        @keys.each_value do |key|
          if BackupEncryption.secure_compare(key, authentication_key)
            raise "BACKUP_ENCRYPTION_KEY must be separate from BACKUP_AUTHENTICATION_KEY"
          end
        end
      end

      def clear!
        @keys.each_value { BackupEncryption.scrub!(_1) }
        @keys.clear
        true
      end
    end

    class << self
      def keyring_from_env!(environment = ENV)
        encoded_active_key = environment.delete(KEY_ENVIRONMENT_VARIABLE)
        active_id = environment.delete(KEY_ID_ENVIRONMENT_VARIABLE)
        encoded_previous_keys = environment.delete(PREVIOUS_KEYS_ENVIRONMENT_VARIABLE)
        decoded_keys = []

        if encoded_active_key.to_s.empty?
          raise "#{KEY_ENVIRONMENT_VARIABLE} is required"
        end
        if active_id.to_s.empty?
          raise "#{KEY_ID_ENVIRONMENT_VARIABLE} is required"
        end

        active_key = decode_key!(encoded_active_key, KEY_ENVIRONMENT_VARIABLE)
        decoded_keys << active_key
        previous_keys = decode_previous_keys!(encoded_previous_keys, decoded_keys)
        Keyring.new(active_id:, active_key:, previous_keys:)
      ensure
        environment.delete KEY_ENVIRONMENT_VARIABLE
        environment.delete KEY_ID_ENVIRONMENT_VARIABLE
        environment.delete PREVIOUS_KEYS_ENVIRONMENT_VARIABLE
        scrub! encoded_active_key
        scrub! encoded_previous_keys
        decoded_keys&.each { scrub!(_1) }
      end

      def validate_key_id!(key_id)
        key_id = key_id.to_s
        unless key_id.bytesize.between?(1, MAX_KEY_ID_BYTES) && key_id.match?(KEY_ID_PATTERN)
          raise "Backup encryption key ID must use 1-64 ASCII letters, digits, dots, underscores, or hyphens"
        end

        key_id.dup.freeze
      end

      def validate_key!(key)
        unless key.is_a?(String) && key.bytesize == KEY_BYTES
          raise "Backup encryption keys must contain exactly 32 random bytes"
        end

        key
      end

      def encrypt_archive(archive_io:, authentication:, destination_io:, keyring:)
        authentication = authentication.to_s.b
        unless authentication.bytesize.between?(1, MAX_AUTHENTICATION_BYTES)
          raise "Backup archive authentication statement is too large"
        end
        nonce = OpenSSL::Random.random_bytes(NONCE_BYTES)
        validate_output! destination_io

        archive_stat = archive_io.stat
        unless archive_stat.file? && archive_stat.size.positive? && archive_stat.size <= MAX_ARCHIVE_BYTES
          raise "Backup plaintext archive is not a bounded regular file"
        end

        bundle_header = [
          BUNDLE_MAGIC, BUNDLE_FORMAT_VERSION, BUNDLE_KIND_ARCHIVE, 0,
          authentication.bytesize, archive_stat.size
        ].pack(BUNDLE_HEADER_PACK)
        payload_bytes = checked_payload_size(bundle_header.bytesize, authentication.bytesize, archive_stat.size)
        key_id = keyring.active_id.b
        fixed_header = [
          MAGIC, FORMAT_VERSION, CIPHER_AES_256_GCM, FLAGS, key_id.bytesize,
          NONCE_BYTES, TAG_BYTES, payload_bytes
        ].pack(HEADER_PACK)
        header = fixed_header + key_id + nonce

        cipher = OpenSSL::Cipher.new("aes-256-gcm")
        cipher.encrypt
        cipher.key = keyring.active_key
        cipher.iv_len = NONCE_BYTES
        cipher.iv = nonce
        cipher.auth_data = header

        destination_io.binmode
        destination_io.write header
        destination_io.write cipher.update(bundle_header)
        destination_io.write cipher.update(authentication)

        archive_io.binmode
        archive_io.rewind
        copy_through_cipher archive_io, destination_io, cipher, archive_stat.size
        raise "Backup plaintext archive changed while it was encrypted" if archive_io.read(1)

        final = cipher.final
        raise "AES-256-GCM produced an unexpected final block" unless final.empty?

        destination_io.write cipher.auth_tag(TAG_BYTES)
        destination_io.flush
        expected_bytes = header.bytesize + payload_bytes + TAG_BYTES
        unless destination_io.stat.size == expected_bytes
          raise "Encrypted backup size does not match its envelope"
        end

        current_archive_stat = archive_io.stat
        unless stable_file?(archive_stat, current_archive_stat)
          raise "Backup plaintext archive changed while it was encrypted"
        end

        { key_id: keyring.active_id, nonce:, payload_bytes:, bytes: expected_bytes }
      end

      def decrypt_archive(source_io:, keyring:, temporary_directory:, maximum_links: 1)
        preflight = preflight_envelope!(source_io, maximum_links:)
        keyring.key_for preflight.fetch(:header).fetch(:key_id)
        ensure_staging_capacity! temporary_directory, preflight.fetch(:header).fetch(:payload_bytes)

        with_unlinked_temporary_file(temporary_directory) do |payload_io|
          envelope = decrypt_envelope(
            source_io:, destination_io: payload_io, keyring:, maximum_links:, preflight:
          )
          payload_io.rewind
          bundle = parse_bundle_header!(payload_io, envelope.fetch(:payload_bytes))
          authentication = read_exact!(
            payload_io, bundle.fetch(:authentication_bytes), "authentication statement"
          )
          archive_offset = payload_io.pos
          unless archive_offset + bundle.fetch(:archive_bytes) == payload_io.stat.size
            raise "Encrypted backup payload has trailing bytes"
          end

          archive_io = ArchiveView.new(
            payload_io, offset: archive_offset, size: bundle.fetch(:archive_bytes)
          )
          yield archive_io, authentication, envelope
        end
      end

      def with_decrypted_archive(path, keyring:, temporary_directory:, &block)
        open_encrypted_file(path) do |source_io|
          decrypt_archive(
            source_io:, keyring:, temporary_directory:, maximum_links: 1, &block
          )
        end
      end

      def envelope_metadata(path)
        open_encrypted_file(path) do |source_io|
          header = preflight_envelope!(source_io, maximum_links: 1).fetch(:header)
          header.slice(:key_id, :nonce, :payload_bytes, :version, :cipher)
        end
      end

      def open_encrypted_file(path)
        open_independent_file(
          path, description: "Encrypted backup source",
          maximum_bytes: HEADER_BYTES + MAX_KEY_ID_BYTES + NONCE_BYTES + MAX_PAYLOAD_BYTES + TAG_BYTES
        ) { yield _1 }
      end

      def open_independent_file(path, description:, maximum_bytes: nil)
        path = Pathname(path).expand_path
        initial = path.lstat
        unless initial.file? && !initial.symlink? && initial.nlink == 1
          raise "#{description} must be an independent regular file"
        end

        flags = File::RDONLY | File::BINARY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        File.open(path, flags) do |file|
          opened = file.stat
          current = path.lstat
          unless opened.file? && opened.nlink == 1 && current.file? &&
              [ opened.dev, opened.ino, opened.ftype ] == [ current.dev, current.ino, current.ftype ]
            raise "#{description} must be an independent regular file"
          end
          if maximum_bytes && !opened.size.between?(1, maximum_bytes)
            raise "#{description} exceeds its safe size limit"
          end

          file.binmode
          file.close_on_exec = true
          yield file
        end
      rescue Errno::ELOOP, Errno::ENOENT, Errno::ENXIO, Errno::ENODEV
        raise "#{description} must be an independent regular file"
      end

      def read_independent_file(path, description:, maximum_bytes:)
        open_independent_file(path, description:, maximum_bytes:) do |file|
          opened = file.stat
          contents = read_exact!(file, opened.size, description.downcase)
          current = file.stat
          unless stable_file?(opened, current) && current.nlink == 1
            raise "#{description} changed while it was read"
          end
          contents
        end
      end

      def with_unlinked_temporary_file(directory)
        directory = private_staging_directory(directory)
        if file = open_anonymous_temporary_file(directory)
          opened = file.stat
          unless opened.file? && opened.nlink.zero?
            raise "Backup plaintext staging could not be made anonymous"
          end
          configure_plaintext_file file
          return yield file
        end

        # Portable filesystems need a named create/unlink sequence; both directory
        # transitions are durable before callers can write plaintext.
        with_create_unlink_temporary_file(directory) { yield _1 }
      ensure
        file&.close unless file&.closed?
      end

      def required_staging_bytes(payload_bytes)
        payload_bytes = Integer(payload_bytes)
        unless payload_bytes.between?(MIN_PAYLOAD_BYTES, MAX_PAYLOAD_BYTES)
          raise "Backup encrypted payload is too large"
        end

        payload_bytes + STAGING_RESERVE_BYTES
      end

      def ensure_staging_capacity!(directory, payload_bytes)
        ensure_plaintext_staging_capacity!(
          directory, payload_bytes, maximum_bytes: MAX_PAYLOAD_BYTES,
          minimum_bytes: MIN_PAYLOAD_BYTES
        )
      end

      def ensure_plaintext_staging_capacity!(directory, bytes, maximum_bytes: MAX_ARCHIVE_BYTES,
          minimum_bytes: 1)
        directory = private_staging_directory(directory)
        bytes = Integer(bytes)
        unless bytes.between?(minimum_bytes, maximum_bytes)
          raise "Backup plaintext staging size is outside its safe limit"
        end
        required = bytes + STAGING_RESERVE_BYTES
        if available_bytes(directory) < required
          raise "Insufficient free space for bounded backup plaintext staging"
        end
        required
      end

      def available_bytes(path)
        output, status = CampfireBackup::Subprocess.capture2("df", "-Pk", Pathname(path).to_s)
        raise "Could not determine backup plaintext staging capacity" unless status.success?

        fields = output.lines.last.to_s.split
        raise "Could not determine backup plaintext staging capacity" if fields.length < 6

        Integer(fields.fetch(3), 10) * 1024
      rescue ArgumentError
        raise "Could not determine backup plaintext staging capacity"
      end

      def secure_compare(left, right)
        left = left.to_s.b
        right = right.to_s.b
        return false unless left.bytesize == right.bytesize

        result = 0
        left.bytes.zip(right.bytes) { |a, b| result |= a ^ b }
        result.zero?
      end

      def scrub!(value)
        value.replace("\0" * value.bytesize) if value.is_a?(String) && !value.frozen?
      rescue FrozenError
        nil
      end

      private
        def private_staging_directory(directory)
          directory = Pathname(directory).expand_path
          directory_stat = directory.lstat
          unless directory_stat.directory? && directory_stat.uid == Process.euid &&
              (directory_stat.mode & 0o077).zero? && !directory.symlink?
            raise "Backup plaintext staging directory must be private"
          end
          directory
        rescue Errno::ENOENT
          raise "Backup plaintext staging directory must be private"
        end

        def open_anonymous_temporary_file(directory)
          return unless RUBY_PLATFORM.match?(/linux/)

          tmpfile_flag = File.const_defined?(:TMPFILE) ? File::TMPFILE : 0o20_200_000
          File.open(directory, File::RDWR | File::BINARY | tmpfile_flag, 0o600)
        rescue Errno::EISDIR, Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOTSUP
          nil
        end

        def with_create_unlink_temporary_file(directory)
          file = nil
          path = nil
          32.times do
            path = directory.join(".campfire-unlinked-#{SecureRandom.hex(16)}")
            flags = File::RDWR | File::CREAT | File::EXCL | File::BINARY
            flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
            begin
              file = File.open(path, flags, 0o600)
              break
            rescue Errno::EEXIST
              next
            end
          end
          raise "Could not create exclusive backup plaintext staging" unless file

          opened = file.stat
          current = path.lstat
          unless opened.file? && opened.nlink == 1 && current.file? &&
              [ opened.dev, opened.ino, opened.ftype ] == [ current.dev, current.ino, current.ftype ]
            raise "Backup plaintext staging changed during creation"
          end

          configure_plaintext_file file
          file.flush
          file.fsync
          flush_directory directory
          path.unlink
          flush_directory directory
          unless file.stat.nlink.zero?
            raise "Backup plaintext staging could not be made private"
          end

          yield file
        ensure
          file&.close unless file&.closed?
          if path && file && defined?(opened) && opened
            begin
              candidate = path.lstat
              if [ candidate.dev, candidate.ino, candidate.ftype ] ==
                  [ opened.dev, opened.ino, opened.ftype ]
                path.unlink
                flush_directory directory
              end
            rescue Errno::ENOENT
              nil
            end
          end
        end

        def configure_plaintext_file(file)
          file.chmod 0o600
          file.binmode
          file.close_on_exec = true
        end

        def flush_directory(path)
          File.open(path, &:fsync)
        end

        def decode_key!(encoded, description)
          Base64.strict_decode64(encoded.to_s).tap do |key|
            unless key.bytesize == KEY_BYTES
              raise "#{description} must be strict Base64 for exactly 32 random bytes"
            end
          end
        rescue ArgumentError
          raise "#{description} must be strict Base64 for exactly 32 random bytes"
        end

        def decode_previous_keys!(encoded, decoded_keys)
          return {} if encoded.to_s.empty?
          if encoded.bytesize > MAX_KEYRING_JSON_BYTES
            raise "#{PREVIOUS_KEYS_ENVIRONMENT_VARIABLE} is too large"
          end

          parsed = JSON.parse(encoded)
          unless parsed.is_a?(Hash) && parsed.size <= MAX_PREVIOUS_KEYS &&
              parsed.all? { |key_id, key| key_id.is_a?(String) && key.is_a?(String) }
            raise "#{PREVIOUS_KEYS_ENVIRONMENT_VARIABLE} must be a JSON object with at most #{MAX_PREVIOUS_KEYS} keys"
          end

          parsed.to_h do |key_id, value|
            decoded = decode_key!(value, "Backup encryption key #{key_id.inspect}")
            decoded_keys << decoded
            [ key_id, decoded ]
          end
        rescue JSON::ParserError
          raise "#{PREVIOUS_KEYS_ENVIRONMENT_VARIABLE} must be a JSON object"
        end

        def validate_nonce!(nonce)
          unless nonce.is_a?(String) && nonce.bytesize == NONCE_BYTES
            raise "Backup encryption nonce must contain exactly #{NONCE_BYTES} bytes"
          end
        end

        def validate_output!(output)
          stat = output.stat
          unless stat.file? && stat.nlink == 1 && stat.size.zero? && output.pos.zero?
            raise "Encrypted backup destination must be a new independent regular file"
          end
        end

        def checked_payload_size(*sizes)
          total = sizes.sum
          unless total.between?(MIN_PAYLOAD_BYTES, MAX_PAYLOAD_BYTES)
            raise "Backup encrypted payload is too large"
          end
          total
        end

        def copy_through_cipher(source, destination, cipher, bytes)
          remaining = bytes
          while remaining.positive?
            chunk = source.read([ remaining, CHUNK_BYTES ].min)
            if chunk.nil? || chunk.empty?
              raise "Backup plaintext archive changed while it was encrypted"
            end

            destination.write cipher.update(chunk)
            remaining -= chunk.bytesize
          end
        end

        def preflight_envelope!(source_io, maximum_links:)
          source_io.binmode
          source_io.rewind
          source_stat = source_io.stat
          unless source_stat.file? && source_stat.nlink.between?(1, maximum_links)
            raise "Encrypted backup source must be an independent regular file"
          end
          header = read_header!(source_io)
          expected_size = checked_envelope_size(header)
          if source_stat.size < expected_size
            raise "Encrypted backup is truncated"
          elsif source_stat.size > expected_size
            raise "Encrypted backup has trailing bytes"
          end

          current_stat = source_io.stat
          unless stable_file?(source_stat, current_stat) && current_stat.nlink.between?(1, maximum_links)
            raise "Encrypted backup source changed during preflight"
          end
          { header:, source_stat: }
        end

        def decrypt_envelope(source_io:, destination_io:, keyring:, maximum_links:, preflight:)
          source_io.binmode
          source_io.rewind
          source_stat = source_io.stat
          header = read_header!(source_io)
          expected_header = preflight.fetch(:header)
          unless stable_file?(preflight.fetch(:source_stat), source_stat) &&
              header.fetch(:authenticated_header) == expected_header.fetch(:authenticated_header) &&
              header.fetch(:payload_bytes) == expected_header.fetch(:payload_bytes)
            raise "Encrypted backup source changed after preflight"
          end

          cipher = OpenSSL::Cipher.new("aes-256-gcm")
          cipher.decrypt
          cipher.key = keyring.key_for(header.fetch(:key_id))
          cipher.iv_len = NONCE_BYTES
          cipher.iv = header.fetch(:nonce)
          cipher.auth_data = header.fetch(:authenticated_header)

          authenticated = false
          written = 0
          remaining = header.fetch(:payload_bytes)
          while remaining.positive?
            chunk = read_exact!(source_io, [ remaining, CHUNK_BYTES ].min, "ciphertext")
            plaintext = cipher.update(chunk)
            destination_io.write plaintext
            written += plaintext.bytesize
            remaining -= chunk.bytesize
          end
          tag = read_exact!(source_io, TAG_BYTES, "authentication tag")
          raise "Encrypted backup has trailing bytes" if source_io.read(1)

          cipher.auth_tag = tag
          final = cipher.final
          destination_io.write final
          written += final.bytesize
          unless written == header.fetch(:payload_bytes)
            raise "Encrypted backup plaintext size does not match its envelope"
          end

          current_stat = source_io.stat
          unless stable_file?(source_stat, current_stat) && current_stat.nlink.between?(1, maximum_links)
            raise "Encrypted backup source changed during decryption"
          end

          destination_io.flush
          destination_io.rewind
          authenticated = true
          header.slice(:key_id, :nonce, :payload_bytes)
        rescue OpenSSL::Cipher::CipherError
          raise "Backup encryption authentication failed"
        ensure
          unless authenticated
            begin
              destination_io.rewind
              destination_io.truncate(0)
            rescue IOError, SystemCallError
              nil
            end
          end
        end

        def read_header!(source)
          fixed = read_exact!(source, HEADER_BYTES, "header")
          magic, version, cipher, flags, key_id_bytes, nonce_bytes, tag_bytes, payload_bytes =
            fixed.unpack(HEADER_PACK)
          raise "Encrypted backup header magic is invalid" unless magic == MAGIC
          raise "Encrypted backup format version is unsupported" unless version == FORMAT_VERSION
          raise "Encrypted backup cipher is unsupported" unless cipher == CIPHER_AES_256_GCM
          raise "Encrypted backup header flags are unsupported" unless flags == FLAGS
          unless key_id_bytes.between?(1, MAX_KEY_ID_BYTES) && nonce_bytes == NONCE_BYTES &&
              tag_bytes == TAG_BYTES && payload_bytes.between?(MIN_PAYLOAD_BYTES, MAX_PAYLOAD_BYTES)
            raise "Encrypted backup header lengths are invalid"
          end

          key_id = read_exact!(source, key_id_bytes, "key ID")
          validate_key_id! key_id
          nonce = read_exact!(source, nonce_bytes, "nonce")
          {
            version:, cipher:, key_id:, nonce:, payload_bytes:,
            authenticated_header: fixed + key_id.b + nonce
          }
        end

        def checked_envelope_size(header)
          HEADER_BYTES + header.fetch(:key_id).bytesize + NONCE_BYTES +
            header.fetch(:payload_bytes) + TAG_BYTES
        end

        def parse_bundle_header!(payload, payload_bytes)
          fixed = read_exact!(payload, BUNDLE_HEADER_BYTES, "payload header")
          magic, version, kind, flags, authentication_bytes, archive_bytes =
            fixed.unpack(BUNDLE_HEADER_PACK)
          unless magic == BUNDLE_MAGIC && version == BUNDLE_FORMAT_VERSION &&
              kind == BUNDLE_KIND_ARCHIVE && flags.zero?
            raise "Encrypted backup payload header is invalid"
          end
          unless authentication_bytes.between?(1, MAX_AUTHENTICATION_BYTES) &&
              archive_bytes.between?(1, MAX_ARCHIVE_BYTES)
            raise "Encrypted backup payload lengths are invalid"
          end
          unless BUNDLE_HEADER_BYTES + authentication_bytes + archive_bytes == payload_bytes
            raise "Encrypted backup payload size does not match its header"
          end

          { authentication_bytes:, archive_bytes: }
        end

        def read_exact!(io, bytes, description)
          result = +"".b
          while result.bytesize < bytes
            chunk = io.read(bytes - result.bytesize)
            raise "Encrypted backup is truncated in its #{description}" if chunk.nil? || chunk.empty?

            result << chunk
          end
          result
        end

        def stable_file?(before, after)
          [ before.dev, before.ino, before.ftype, before.size ] ==
            [ after.dev, after.ino, after.ftype, after.size ]
        end
    end
  end
end
