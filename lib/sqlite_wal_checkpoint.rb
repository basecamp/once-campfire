# SQLite auto-checkpoints the WAL on the writer (~1,000 pages), which fsyncs
# during the committing request. Disable that and copy pages off the request
# thread with PASSIVE checkpoints instead.
class SqliteWalCheckpoint
  INTERVAL = 0.25

  class << self
    def start(interval: INTERVAL)
      new(interval: interval).start
    end

    def database_path
      config = ActiveRecord::Base.connection_db_config
      return unless config.adapter.to_s == "sqlite3"

      ActiveRecord::ConnectionAdapters::SQLite3Adapter.resolve_path(config.database)
    end
  end

  def initialize(interval: INTERVAL)
    @interval = interval
  end

  def start
    Thread.new { run }
  end

  def checkpoint
    path = self.class.database_path
    return unless path && File.exist?(path)

    SQLite3::Database.new(path) do |database|
      database.wal_checkpoint = "PASSIVE"
    end
  end

  private
    def run
      Thread.current.name = "sqlite-wal-checkpoint"

      loop do
        run_with_connection
      rescue => error
        Rails.logger.warn "SQLite WAL checkpoint failed: #{error.class}: #{error.message}"
        sleep @interval
      end
    end

    def run_with_connection
      path = self.class.database_path
      unless path && File.exist?(path)
        sleep @interval
        return
      end

      SQLite3::Database.new(path) do |database|
        loop do
          database.wal_checkpoint = "PASSIVE"
          sleep @interval
        end
      end
    end
end
