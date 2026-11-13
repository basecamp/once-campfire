# SQLite's default WAL auto-checkpoint (~1,000 pages) runs inside the committing
# writer and fsyncs during the request. database.yml sets wal_autocheckpoint=0;
# this module copies pages off the request thread with PASSIVE checkpoints.
#
# Every non-test process starts a contender. Callers that fork must stop before
# fork and start again in the child so the flock is never shared across an
# inherited file descriptor.
module SqliteWalCheckpoint
  INTERVAL = 0.25
  MAX_BACKOFF = 30.0
  STOP_TIMEOUT = 5.0
  LOCK_PATH = Rails.root.join("tmp/pids/sqlite_wal_checkpoint.lock")
  LIFECYCLE_MUTEX = Mutex.new
  private_constant :LIFECYCLE_MUTEX

  class StopTimeout < StandardError; end

  class << self
    attr_writer :lock_path, :database_path_override

    def start(interval: INTERVAL, enabled: !Rails.env.test?)
      return unless enabled

      LIFECYCLE_MUTEX.synchronize do
        if @thread&.alive?
          raise StopTimeout, "SQLite WAL checkpointer is still stopping" if @wakeup.closed?

          return @thread
        end

        @wakeup = Thread::Queue.new
        install_exit_checkpoint
        @thread = Thread.new(@wakeup) { |wakeup| run(interval, wakeup) }
        @thread.report_on_exception = false
        @thread
      end
    end

    # Signal the contender to exit and wait until it has released the flock and
    # closed its SQLite connection. before_fork must not return while those are open.
    def stop(timeout: STOP_TIMEOUT)
      LIFECYCLE_MUTEX.synchronize do
        return unless @thread

        @wakeup.close
        unless @thread.join(timeout)
          # Never let a caller fork with live SQLite or flock ownership.
          raise StopTimeout, "SQLite WAL checkpointer did not stop within #{timeout}s"
        end
        @thread = @wakeup = nil
      end
    end

    def checkpoint
      with_database { |database| checkpoint_on(database) }
    end

    # One leadership attempt for tests: acquire the lock, checkpoint once, release.
    def tick
      return :no_database unless database_path
      lock = acquire_lock
      return :busy unless lock

      begin
        result = checkpoint
        result.nil? ? :no_database : :checkpointed
      ensure
        release_lock(lock)
      end
    end

    def lock_path
      @lock_path || LOCK_PATH
    end

    def reset!
      stop
      @lock_path = nil
      @database_path_override = nil
    end

    private
      def run(interval, wakeup)
        Thread.current.name = "sqlite-wal-checkpoint"
        backoff = interval

        until wakeup.closed?
          begin
            path = database_path
            unless path && File.exist?(path)
              wait(wakeup, interval)
              next
            end

            lock = acquire_lock
            unless lock
              wait(wakeup, interval)
              next
            end

            begin
              ran = false
              with_database do |database|
                ran = true
                until wakeup.closed?
                  checkpoint_on(database)
                  backoff = interval
                  wait(wakeup, interval)
                end
              end
            ensure
              release_lock(lock)
            end

            # with_database no-ops if the file vanished between the exist? check
            # and open; sleep so we do not spin on the lock file.
            wait(wakeup, interval) unless ran || wakeup.closed?
          rescue => error
            Rails.logger.warn "SQLite WAL checkpoint failed: #{error.class}: #{error.message}"
            wait(wakeup, backoff)
            backoff = [ backoff * 2, MAX_BACKOFF ].min
          end
        end
      end

      def wait(wakeup, timeout)
        wakeup.pop(timeout: timeout)
      end

      def checkpoint_on(database)
        database.execute("PRAGMA wal_checkpoint(PASSIVE)").first
      end

      def with_database
        path = database_path
        return unless path && File.exist?(path)

        result = nil
        SQLite3::Database.new(path) do |database|
          # Bounds busy-handler retries, not PASSIVE checkpoint I/O.
          database.busy_handler_timeout = 1_000
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
          file
        else
          file.close
          nil
        end
      rescue
        file&.close
        raise
      end

      def release_lock(file)
        return unless file

        file.flock(File::LOCK_UN)
      ensure
        file&.close
      end

      # Best-effort PASSIVE for short-lived console/rake writers that exit before
      # the contender acquires the flock. Does not touch lock ownership.
      def install_exit_checkpoint
        return if @exit_checkpoint_installed

        @exit_checkpoint_installed = true
        at_exit { checkpoint rescue nil }
      end
  end
end
