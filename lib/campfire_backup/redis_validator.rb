require "pathname"
require_relative "subprocess"

module CampfireBackup
  module RedisValidator
    class << self
      def validate!(payload_directory)
        source = Pathname(payload_directory).join("redis")
        return unless path_exists?(source)
        raise "Redis backup path is not a directory" unless regular_directory?(source)

        validate_directory! source
      end

      private
        def validate_directory!(directory)
          appendonly_directory = directory.join("appendonlydir")
          manifest = appendonly_directory.join("appendonly.aof.manifest")
          legacy_aof = directory.join("appendonly.aof")
          allowed_root_entries = %w[ appendonly.aof appendonlydir dump.rdb ]
          unknown_entries = directory.children.reject { _1.basename.to_s.in?(allowed_root_entries) }
          raise "Redis backup contains an unsupported persistence layout" if unknown_entries.any?

          if path_exists?(legacy_aof) && !regular_file?(legacy_aof)
            raise "Redis backup appendonly.aof is not a regular file"
          end
          rdb = directory.join("dump.rdb")
          if path_exists?(rdb) && !regular_file?(rdb)
            raise "Redis backup dump.rdb is not a regular file"
          end

          if path_exists?(appendonly_directory)
            unless regular_directory?(appendonly_directory)
              raise "Redis backup appendonlydir is not a directory"
            end
            raise "Redis backup mixes legacy and multi-part AOF layouts" if path_exists?(legacy_aof)
            unless regular_file?(manifest)
              raise "Redis backup contains AOF files without a loadable manifest"
            end

            expected_files = manifest.read.lines.map { parse_manifest_entry!(_1) }
            raise "Redis backup manifest contains duplicate files" unless expected_files.uniq.size == expected_files.size
            actual_files = appendonly_directory.children.map do |path|
              unless regular_file?(path)
                raise "Redis backup contains nested directories, links, or special files"
              end
              path.basename.to_s
            end
            unless actual_files.sort == ([ manifest.basename.to_s ] + expected_files).sort
              raise "Redis backup contains missing or orphaned multi-part AOF files"
            end
            run! "redis-check-aof", manifest
          elsif path_exists?(legacy_aof)
            run! "redis-check-aof", legacy_aof
          end

          run! "redis-check-rdb", rdb if path_exists?(rdb)
        end

        def path_exists?(path)
          path.lstat
          true
        rescue Errno::ENOENT
          false
        end

        def regular_directory?(path)
          path.lstat.directory?
        rescue Errno::ENOENT
          false
        end

        def regular_file?(path)
          path.lstat.file?
        rescue Errno::ENOENT
          false
        end

        def parse_manifest_entry!(line)
          offset = /(?:0|[1-9]\d*)/
          match = line.match(
            /\Afile ([^\s\/]+) seq [1-9]\d* type [bih](?: startoffset #{offset}(?: endoffset #{offset})?)?\n?\z/
          )
          raise "Redis backup contains an invalid AOF manifest entry" unless match

          match[1]
        end

        def run!(command, path)
          stdout, stderr, status = CampfireBackup::Subprocess.capture3(command, path.to_s)
          return if status.success?

          details = [ stdout, stderr ].join(" ").gsub(/\s+/, " ").strip
          raise "Redis backup validation failed: #{details.empty? ? command : details}"
        rescue Errno::ENOENT
          raise "Redis backup validation requires #{command}"
        end
    end
  end
end
