# SQLite's default WAL auto-checkpoint (~1,000 pages) runs inside the committing
# writer and fsyncs during the request. database.yml sets wal_autocheckpoint=0;
# this module copies pages off the request thread with PASSIVE checkpoints.
#
# Every non-test writer process starts a contender thread (initializer, Puma,
# Resque). A file lock elects one leader; if that process exits, another takes
# over on the next interval so auto-checkpoint stays off safely.
module SqliteWalCheckpoint
  INTERVAL = 0.25
  MAX_BACKOFF = 30.0
  LOCK_PATH = Rails.root.join("tmp/pids/sqlite_wal_checkpoint.lock")

  class << self
    attr_writer :lock_path, :database_path_override

    def start(interval: INTERVAL, enabled: !Rails.env.test?)
      return unless enabled

      @mutex ||= Mutex.new
      @mutex.synchronize do
        return if @thread&.alive?

        @stop = false
        install_exit_handler
        @thread = Thread.new { run(interval) }
        @thread.report_on_exception = false
      end

      @thread
    end

    def stop
      @stop = true
      thread = @mutex&.synchronize { @thread }
      thread&.join(2)
    ensure
      @mutex&.synchronize { @thread = nil if @thread && !@thread.alive? }
      release_lock
    end

    def checkpoint
      with_database { |database| checkpoint_on(database) }
    end

    # One leadership attempt for tests: acquire the lock, checkpoint once, release.
    def tick
      return :no_database unless database_path
      return :busy unless acquire_lock

      begin
        result = checkpoint
        result.nil? ? :no_database : :checkpointed
      ensure
        release_lock
      end
    end

    def lock_path
      @lock_path || LOCK_PATH
    end

    def reset!
      stop
      @lock_path = nil
      @database_path_override = nil
      @stop = false
      @exit_handler_installed = false
    end

    # Puma's WEB_CONCURRENCY=auto must not use to_i (that is 0). Only the literal
    # 0 means single-process mode; everything else forks workers.
    def single_puma_process?(configured_workers)
      configured_workers.to_s == "0"
    end

    private
      def run(interval)
        Thread.current.name = "sqlite-wal-checkpoint"
        backoff = interval

        until @stop
          begin
            unless database_path
              interruptible_sleep interval
              next
            end

            unless acquire_lock
              interruptible_sleep interval
              next
            end

            begin
              with_database do |database|
                until @stop
                  checkpoint_on(database)
                  backoff = interval
                  interruptible_sleep interval
                end
              end
            ensure
              release_lock
            end
          rescue => error
            Rails.logger.warn "SQLite WAL checkpoint failed: #{error.class}: #{error.message}"
            interruptible_sleep backoff
            backoff = [ backoff * 2, MAX_BACKOFF ].min
          end
        end
      ensure
        release_lock
      end

      def checkpoint_on(database)
        database.execute("PRAGMA wal_checkpoint(PASSIVE)").first
      end

      def with_database
        path = database_path
        return unless path && File.exist?(path)

        result = nil
        SQLite3::Database.new(path) do |database|
          database.busy_handler_timeout = 5_000
          result = yield database
        end
        result
      end

      def database_path
        return @database_path_override if @database_path_override

        config = ActiveRecord::Base.connection_db_config
        return unless config.adapter.to_s == "sqlite3"

        ActiveRecord::ConnectionAdapters::SQLite3Adapter.resolve_path(config.database)
      end

      def acquire_lock
        FileUtils.mkdir_p(File.dirname(lock_path))
        file = File.open(lock_path, File::RDWR | File::CREAT, 0644)
        if file.flock(File::LOCK_EX | File::LOCK_NB)
          @lock_file = file
          true
        else
          file.close
          false
        end
      end

      def release_lock
        return unless @lock_file

        @lock_file.flock(File::LOCK_UN)
        @lock_file.close
      rescue Errno::EBADF, IOError
        # Already closed by a racing ensure / exit handler.
      ensure
        @lock_file = nil
      end

      def interruptible_sleep(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        while !@stop && (remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)) > 0
          sleep [ remaining, 0.05 ].min
        end
      end

      def install_exit_handler
        return if @exit_handler_installed

        @exit_handler_installed = true
        at_exit do
          if @lock_file
            checkpoint rescue nil
          end
          stop
        end
      end
  end
end
