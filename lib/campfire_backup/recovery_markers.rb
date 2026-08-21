require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "descriptor_tree"

module CampfireBackup
  module RecoveryMarkers
    FORMAT_VERSION = 1
    RESTORE_FILENAME = "restore-in-progress.json"
    CLEAN_SHUTDOWN_FILENAME = "clean-shutdown.json"
    RESTORE_KIND = "campfire-restore-in-progress"
    CLEAN_SHUTDOWN_KIND = "campfire-clean-shutdown"
    IDENTIFIER_PATTERN = /\A[0-9a-f]{32}\z/

    Marker = Struct.new(:path, :identity, keyword_init: true)

    class << self
      def new_boot_id
        SecureRandom.hex(16)
      end

      def assert_restore_complete!(storage_directory, descriptor_tree: nil)
        path = marker_path(storage_directory, RESTORE_FILENAME)
        missing = descriptor_tree ? descriptor_tree.entry_missing?(RESTORE_FILENAME) : !path_exists?(path)
        return true if missing

        raise "A previous restore did not complete. Do not boot or retry this volume. " \
          "Discard and recreate this disposable restore destination, then rerun the full restore: #{path.dirname}"
      end

      def begin_restore!(storage_directory, backup_id:, operation_id:, now: Time.now.utc,
          descriptor_tree: nil)
        assert_restore_complete!(storage_directory, descriptor_tree:)
        write_marker(
          marker_path(storage_directory, RESTORE_FILENAME),
          {
            format_version: FORMAT_VERSION,
            kind: RESTORE_KIND,
            operation_id:,
            backup_id:,
            started_at: now.utc.iso8601
          },
          preserve_on_failure: true, descriptor_tree:
        )
      end

      def complete_restore!(marker, descriptor_tree: nil)
        remove_marker! marker.path, expected_identity: marker.identity,
          description: "Restore-in-progress marker", descriptor_tree:
      end

      def invalidate_clean_shutdown!(storage_directory)
        path = marker_path(storage_directory, CLEAN_SHUTDOWN_FILENAME)
        return true unless path_exists?(path)

        remove_marker! path, description: "Clean-shutdown marker"
      end

      def verify_clean_shutdown!(storage_directory)
        path = marker_path(storage_directory, CLEAN_SHUTDOWN_FILENAME)
        raise "Campfire clean-shutdown proof is missing" unless path_exists?(path)

        payload = JSON.parse(read_independent_file(path, "Clean-shutdown marker"))
        unless payload.keys.sort == %w[ boot_id format_version kind stopped_at ] &&
            payload.fetch("format_version") == FORMAT_VERSION &&
            payload.fetch("kind") == CLEAN_SHUTDOWN_KIND &&
            payload.fetch("boot_id").match?(IDENTIFIER_PATTERN)
          raise "Campfire clean-shutdown proof is invalid"
        end
        Time.iso8601(payload.fetch("stopped_at"))
        payload
      rescue JSON::ParserError, KeyError, NoMethodError, TypeError, ArgumentError
        raise "Campfire clean-shutdown proof is invalid"
      end

      def publish_clean_shutdown!(storage_directory, boot_id:, now: Time.now.utc)
        unless boot_id.to_s.match?(IDENTIFIER_PATTERN)
          raise "Campfire boot identity is invalid"
        end

        storage_directory = independent_directory(storage_directory, "Campfire storage")
        flush_redis_persistence! storage_directory.join("redis")
        write_marker(
          storage_directory.join(CLEAN_SHUTDOWN_FILENAME),
          {
            format_version: FORMAT_VERSION,
            kind: CLEAN_SHUTDOWN_KIND,
            boot_id:,
            stopped_at: now.utc.iso8601
          },
          preserve_on_failure: false
        )
        true
      end

      def marker_filename?(name)
        [ RESTORE_FILENAME, CLEAN_SHUTDOWN_FILENAME ].include?(name.to_s)
      end

      private
        def marker_path(storage_directory, filename)
          independent_directory(storage_directory, "Campfire storage").join(filename)
        end

        def write_marker(path, payload, preserve_on_failure:, descriptor_tree: nil)
          return write_descriptor_marker(
            path, payload, preserve_on_failure:, descriptor_tree:
          ) if descriptor_tree

          raise "Recovery marker already exists: #{path}" if path_exists?(path)

          flags = File::WRONLY | File::CREAT | File::EXCL
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          file = File.open(path, flags, 0o600)
          opened = file.stat
          identity = file_identity(opened)
          assert_independent_file! file, path, "Recovery marker"
          file.chmod 0o600
          file.write JSON.generate(payload) << "\n"
          file.flush
          file.fsync
          assert_independent_file! file, path, "Recovery marker", expected_identity: identity
          flush_directory path.dirname
          committed = true
          Marker.new(path:, identity:)
        ensure
          file&.close
          unless committed || preserve_on_failure || !defined?(identity) || !identity
            remove_failed_marker path, identity
          end
        end

        def remove_failed_marker(path, identity)
          tree = DescriptorTree.new(path.dirname, description: "Recovery marker parent")
          tree.remove(path.basename.to_s, expected_identity: identity, directory: false)
          tree.flush_root
        rescue StandardError
          nil
        ensure
          tree&.close
        end

        def write_descriptor_marker(path, payload, preserve_on_failure:, descriptor_tree:)
          relative = path.basename.to_s
          committed = false
          identity = nil
          marker = nil
          raise "Recovery marker already exists: #{path}" unless descriptor_tree.entry_missing?(relative)

          descriptor_tree.create_file(relative, mode: 0o600) do |file, opened|
            identity = file_identity(opened)
            file.chmod 0o600
            file.write JSON.generate(payload) << "\n"
            file.flush
            file.fsync
          end
          descriptor_tree.flush_root
          committed = true
          marker = Marker.new(path:, identity:)
          marker
        ensure
          unless committed || preserve_on_failure || !defined?(identity) || !identity
            begin
              descriptor_tree.remove(relative, expected_identity: identity, directory: false)
              descriptor_tree.flush_root
            rescue StandardError
              nil
            end
          end
        end

        def remove_marker!(path, expected_identity: nil, description:, descriptor_tree: nil)
          if descriptor_tree
            relative = path.basename.to_s
            identity = nil
            descriptor_tree.open_regular_file(relative, expected_identity:) do |_file, opened|
              identity = file_identity(opened)
            end
            descriptor_tree.remove(relative, expected_identity: identity, directory: false)
            descriptor_tree.flush_root
            return true
          end

          tree = DescriptorTree.new(path.dirname, description: "#{description} parent")
          identity = nil
          tree.open_regular_file(path.basename.to_s, expected_identity:) do |_file, opened|
            identity = file_identity(opened)
          end
          tree.remove(path.basename.to_s, expected_identity: identity, directory: false)
          tree.flush_root
          true
        rescue Errno::ENOENT
          raise "#{description} disappeared while it was being removed"
        ensure
          tree&.close
        end

        def read_independent_file(path, description)
          flags = File::RDONLY
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(path, flags) do |file|
            identity = assert_independent_file! file, path, description
            contents = file.read
            unless current_identity(path) == identity
              raise "#{description} changed while it was being read"
            end
            contents
          end
        rescue Errno::ENOENT
          raise "#{description} disappeared while it was being read"
        end

        def assert_independent_file!(file, path, description, expected_identity: nil)
          opened = file.stat
          current = path.lstat
          identity = file_identity(opened)
          unless opened.file? && opened.nlink == 1 && current.file? &&
              identity == file_identity(current) && (!expected_identity || identity == expected_identity)
            raise "#{description} is not the expected independent regular file"
          end
          identity
        end

        def flush_redis_persistence!(directory)
          directory = independent_directory(directory, "Redis persistence directory")
          entries = Dir.glob(directory.join("**", "*"), File::FNM_DOTMATCH).filter_map do |name|
            path = Pathname(name)
            next if %w[ . .. ].include?(path.basename.to_s)

            stat = path.lstat
            if stat.file?
              flush_regular_file path
              nil
            elsif stat.directory? && !stat.symlink?
              path
            else
              raise "Redis persistence contains a link or special file"
            end
          end
          entries.sort_by { _1.each_filename.count }.reverse_each { flush_directory(_1) }
          flush_directory directory
        end

        def flush_regular_file(path)
          flags = File::RDONLY
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(path, flags) do |file|
            identity = assert_independent_file! file, path, "Redis persistence file"
            file.fsync
            unless current_identity(path) == identity
              raise "Redis persistence file changed while it was being flushed"
            end
          end
        end

        def independent_directory(path, description)
          path = Pathname(path).expand_path
          stat = path.lstat
          unless stat.directory? && !stat.symlink?
            raise "#{description} is not an independent directory"
          end
          path
        rescue Errno::ENOENT
          raise "#{description} does not exist"
        end

        def current_identity(path)
          file_identity path.lstat
        rescue Errno::ENOENT
          nil
        end

        def file_identity(stat)
          [ stat.dev, stat.ino, stat.ftype ]
        end

        def path_exists?(path)
          path.lstat
          true
        rescue Errno::ENOENT
          false
        end

        def flush_directory(path)
          File.open(path, &:fsync)
        end
    end
  end
end
