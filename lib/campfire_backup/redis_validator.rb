require "fileutils"
require "pathname"
require "socket"
require "tmpdir"
require_relative "subprocess"

module CampfireBackup
  module RedisValidator
    ManifestEntry = Data.define(:filename, :sequence, :type)
    MANIFEST_TYPE_ORDER = { "b" => 0, "h" => 1, "i" => 2 }.freeze
    MAX_MANIFEST_SEQUENCE = (2**63) - 1
    REPLAY_TIMEOUT = 5 * 60

    class << self
      def validate!(payload_directory, require_aof: false)
        source = Pathname(payload_directory).join("redis")
        unless path_exists?(source)
          raise "Redis backup is missing required AOF persistence" if require_aof
          return
        end
        raise "Redis backup path is not a directory" unless regular_directory?(source)

        validate_directory! source, require_aof:
      end

      private
        def validate_directory!(directory, require_aof:)
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

            entries = manifest.read.lines.map { parse_manifest_entry!(_1) }
            validate_manifest_entries! entries, require_aof:
            expected_files = entries.map(&:filename)
            unless expected_files.uniq.size == expected_files.size
              raise "Redis backup manifest contains duplicate files"
            end
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

          if require_aof && !path_exists?(appendonly_directory) && !path_exists?(legacy_aof)
            raise "Redis backup is missing required AOF persistence"
          end
          if path_exists?(rdb) && !path_exists?(appendonly_directory) && !path_exists?(legacy_aof)
            raise "Redis backup contains only dump.rdb, but this image requires AOF persistence"
          end
          run! "redis-check-rdb", rdb if path_exists?(rdb)
          if path_exists?(appendonly_directory) || path_exists?(legacy_aof)
            replay_with_target_server! directory, required: require_aof
          end
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
            /\Afile ([^\s\/]+) seq ([1-9]\d*) type ([bih])(?: startoffset #{offset}(?: endoffset #{offset})?)?\n?\z/
          )
          raise "Redis backup contains an invalid AOF manifest entry" unless match

          sequence = Integer(match[2], 10)
          if sequence > MAX_MANIFEST_SEQUENCE
            raise "Redis backup contains an invalid AOF manifest entry"
          end

          ManifestEntry.new(match[1], sequence, match[3])
        end

        def validate_manifest_entries!(entries, require_aof:)
          raise "Redis backup contains an empty AOF manifest" if entries.empty?
          if entries.count { _1.type == "b" } > 1
            raise "Redis backup AOF manifest contains multiple base files"
          end

          order = entries.map { MANIFEST_TYPE_ORDER.fetch(_1.type) }
          unless order.each_cons(2).all? { |left, right| left <= right }
            raise "Redis backup AOF manifest entries are out of order"
          end

          incremental_sequences = entries.select { _1.type == "i" }.map(&:sequence)
          unless incremental_sequences.each_cons(2).all? { |left, right| left < right }
            raise "Redis backup AOF manifest contains non-monotonic incremental sequences"
          end

          active = entries.any? { _1.type.in?([ "b", "i" ]) }
          unless active
            message = "Redis backup AOF manifest contains only history files"
            message += " and is missing required active AOF persistence" if require_aof
            raise message
          end
        end

        def run!(command, path)
          if command == "redis-check-aof" && !writable_aof_input?(path)
            return with_writable_aof_copy(path) { run!(command, _1) }
          end

          stdout, stderr, status = CampfireBackup::Subprocess.capture3(command, path.to_s)
          return if status.success?

          details = [ stdout, stderr ].join(" ").gsub(/\s+/, " ").strip
          raise "Redis backup validation failed: #{details.empty? ? command : details}"
        rescue Errno::ENOENT
          raise "Redis backup validation requires #{command}"
        end

        def writable_aof_input?(path)
          paths = path.basename.to_s.end_with?(".manifest") ? path.dirname.children : [ path ]
          paths.all? do |candidate|
            File.open(candidate, File::RDWR, &:close)
            true
          rescue Errno::EACCES, Errno::EPERM, Errno::EROFS
            false
          end
        end

        def with_writable_aof_copy(path)
          Dir.mktmpdir("campfire-redis-validation") do |directory|
            destination_directory = Pathname(directory)
            sources = path.basename.to_s.end_with?(".manifest") ? path.dirname.children : [ path ]
            sources.each do |source|
              destination = destination_directory.join(source.basename)
              FileUtils.copy_file source, destination
              File.chmod 0o600, destination
            end
            yield destination_directory.join(path.basename)
          end
        end

        def replay_with_target_server!(source, required:)
          executable = redis_server_executable
          unless executable
            raise "Redis backup validation requires redis-server for target replay" if required

            return
          end

          Dir.mktmpdir("campfire-redis-replay") do |directory|
            root = Pathname(directory)
            copy = root.join("redis")
            FileUtils.copy_entry source, copy
            FileUtils.chmod_R 0o700, copy
            run_replay_server! executable, copy, root.join("redis.sock"), root.join("redis.log")
          end
        end

        def redis_server_executable
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
            next if directory.empty?

            candidate = Pathname(directory).join("redis-server")
            candidate.to_s if candidate.file? && candidate.executable?
          end.first
        end

        def run_replay_server!(executable, directory, socket_path, log_path)
          arguments = [
            "--port", "0",
            "--protected-mode", "no",
            "--daemonize", "no",
            "--dir", directory.to_s,
            "--dbfilename", "dump.rdb",
            "--appendonly", "yes",
            "--appendfilename", "appendonly.aof",
            "--appenddirname", "appendonlydir",
            "--appendfsync", "no",
            "--auto-aof-rewrite-percentage", "0",
            "--aof-load-truncated", "no",
            "--propagation-error-behavior", "panic",
            "--save", "",
            "--unixsocket", socket_path.to_s,
            "--unixsocketperm", "700"
          ]
          environment = ENV.slice(*CampfireBackup::Subprocess::INHERITED_ENVIRONMENT_VARIABLES)
          pid = nil
          reaped = false
          log = File.open(log_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600)
          pid = Process.spawn(
            environment, executable, *arguments, unsetenv_others: true,
            out: log, err: [ :child, :out ]
          )
          log.close
          log = nil
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REPLAY_TIMEOUT

          loop do
            waited_pid, status = Process.waitpid2(pid, Process::WNOHANG)
            if waited_pid
              reaped = true
              raise replay_failure(log_path, status)
            end

            if path_exists?(socket_path)
              begin
                socket = UNIXSocket.new(socket_path.to_s)
                socket.write("*1\r\n$4\r\nPING\r\n")
                if IO.select([ socket ], nil, nil, 1) && socket.gets == "+PONG\r\n"
                  break
                end
              rescue Errno::ECONNREFUSED, Errno::ENOENT
                nil
              ensure
                socket&.close
              end
            end

            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              raise "Redis backup target-server replay timed out"
            end
            sleep 0.05
          end
        ensure
          log&.close
          stop_replay_server(pid) if pid && !reaped
        end

        def replay_failure(log_path, status)
          details = if log_path.file?
            File.read(log_path, 4096).to_s.gsub(/\s+/, " ").strip
          else
            ""
          end
          outcome = status.signaled? ? "redis-server signal #{status.termsig}" : "redis-server exit #{status.exitstatus}"
          "Redis backup target-server replay failed: #{details.empty? ? outcome : details}"
        end

        def stop_replay_server(pid)
          begin
            Process.kill("TERM", pid)
          rescue Errno::ESRCH
            Process.waitpid(pid)
            return
          end
          100.times do
            return if Process.waitpid(pid, Process::WNOHANG)

            sleep 0.01
          end
          Process.kill("KILL", pid)
          Process.waitpid(pid)
        rescue Errno::ESRCH
          Process.waitpid(pid)
        rescue Errno::ECHILD
          nil
        end
    end
  end
end
