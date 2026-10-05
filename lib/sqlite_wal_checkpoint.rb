# SQLite auto-checkpoints the WAL on the writer (~1,000 pages), which fsyncs
# during the committing request. Disable that in database.yml and copy pages
# off the request thread with PASSIVE checkpoints from a writer process.
module SqliteWalCheckpoint
  INTERVAL = 0.25
  LOCK_PATH = Rails.root.join("tmp/pids/sqlite_wal_checkpoint.lock")

  class << self
    def start(interval: INTERVAL)
      return if Rails.env.test?

      @mutex ||= Mutex.new
      @mutex.synchronize do
        return if @thread&.alive?

        @thread = Thread.new { run(interval) }
      end
    end

    def checkpoint
      with_database { |database| database.execute("PRAGMA wal_checkpoint(PASSIVE)") }
    end

    private
      def database_path
        config = ActiveRecord::Base.connection_db_config
        return unless config.adapter.to_s == "sqlite3"

        ActiveRecord::ConnectionAdapters::SQLite3Adapter.resolve_path(config.database)
      end

      def run(interval)
        Thread.current.name = "sqlite-wal-checkpoint"

        loop do
          unless acquire_lock
            sleep interval
            next
          end

          begin
            with_database do |database|
              loop do
                database.execute("PRAGMA wal_checkpoint(PASSIVE)")
                sleep interval
              end
            end
          ensure
            release_lock
          end
        rescue => error
          Rails.logger.warn "SQLite WAL checkpoint failed: #{error.class}: #{error.message}"
          sleep interval
        end
      end

      def with_database
        path = database_path
        return unless path && File.exist?(path)

        SQLite3::Database.new(path) do |database|
          database.busy_handler_timeout = 5_000
          yield database
        end
      end

      def acquire_lock
        FileUtils.mkdir_p(File.dirname(LOCK_PATH))
        file = File.open(LOCK_PATH, File::RDWR | File::CREAT, 0644)
        if file.flock(File::LOCK_EX | File::LOCK_NB)
          @lock_file = file
          true
        else
          file.close
          false
        end
      end

      def release_lock
        @lock_file&.flock(File::LOCK_UN)
        @lock_file&.close
      ensure
        @lock_file = nil
      end
  end
end
