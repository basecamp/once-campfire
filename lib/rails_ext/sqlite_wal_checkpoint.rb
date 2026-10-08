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
  LOCK_PATH = Rails.root.join("tmp/pids/sqlite_wal_checkpoint.lock")

  class << self
    attr_writer :lock_path, :database_path_override

    def start(interval: INTERVAL, enabled: !Rails.env.test?)
      return unless enabled

      @mutex ||= Mutex.new
      @mutex.synchronize do
        return if @thread&.alive?

        @stop = false
        install_exit_checkpoint
        @thread = Thread.new { run(interval) }
        @thread.report_on_exception = false
      end

      @thread
    end

    # Signal the contender to exit and wait until it has released the flock and
    # closed its SQLite connection. before_fork must not return while those are open.
    def stop
      @stop = true
      thread = @mutex&.synchronize { @thread }
      return unless thread

      thread.join
      @mutex&.synchronize { @thread = nil if @thread.equal?(thread) }
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
      @exit_checkpoint_installed = false
    end

    private
      def run(interval)
        Thread.current.name = "sqlite-wal-checkpoint"
        backoff = interval

        until @stop
          begin
            path = database_path
            unless path && File.exist?(path)
              sleep interval
              next
            end

            unless acquire_lock
              sleep interval
              next
            end

            begin
              ran = false
              with_database do |database|
                ran = true
                until @stop
                  checkpoint_on(database)
                  backoff = interval
                  sleep interval
                end
              end
            ensure
              release_lock
            end

            # with_database no-ops if the file vanished between the exist? check
            # and open; sleep so we do not spin on the lock file.
            sleep interval unless ran || @stop
          rescue => error
            Rails.logger.warn "SQLite WAL checkpoint failed: #{error.class}: #{error.message}"
            sleep backoff
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
          # Keep below stop's join timeout so before_fork can finish cleanly.
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
      ensure
        @lock_file = nil
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
