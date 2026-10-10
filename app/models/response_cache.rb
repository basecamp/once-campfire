require "sqlite3"

# A read-only observer sees commits from every writer, including other runtimes.
# PRAGMA data_version can only be compared on the same persistent connection.
class ResponseCache
  MAX_ENTRY_BYTES = 1.megabyte
  MAX_KEY_BYTES = 2.kilobytes

  attr_reader :budget

  def self.instance
    INSTANCE
  end

  def initialize(budget: [ ENV.fetch("CAMPFIRE_RESPONSE_CACHE_MB", "64").to_i, 0 ].max.megabytes)
    @budget = budget
    @store = ActiveSupport::Cache::MemoryStore.new(size: budget, coder: nil)
    @mutex = Mutex.new
    @render_locks = Array.new(16) { Mutex.new }
  end

  def version
    @mutex.synchronize { current_version }
  rescue SQLite3::Exception
    clear
    nil
  end

  def read(key, version)
    @mutex.synchronize do
      if current_version == version
        entry = @store.read(key)
        entry if current_version == version
      end
    end
  rescue SQLite3::Exception
    clear
    nil
  end

  # Collapse cold renders without retaining a mutex for every viewer or URL.
  # Rendering must never hold the observer/entry mutex: controllers read it too.
  def synchronize_render(key, version, &block)
    @render_locks[[ key, version ].hash % @render_locks.length].synchronize(&block)
  end

  def write(key, version, entry)
    size = key.bytesize + entry[:body].bytesize + entry[:headers].sum { |name, value| name.bytesize + value.bytesize } + 256
    return if key.bytesize > MAX_KEY_BYTES || size > [ budget, MAX_ENTRY_BYTES ].min

    @mutex.synchronize do
      return unless current_version == version
      @store.write(key, entry, unless_exist: true)
    end
  rescue SQLite3::Exception
    clear
  end

  def clear
    @mutex.synchronize do
      @store.clear
      @observer&.close
      @observer = @database = @version = nil
    end
  end

  private
    def current_version
      database = File.expand_path(ActiveRecord::Base.connection_db_config.database)
      if @database != database || !@observer
        @store.clear
        @observer&.close
        @observer = nil
        @observer = SQLite3::Database.new(database, readonly: true)
        @database = database
        @namespace = SecureRandom.hex(16)
        @version = nil
      end

      version = @observer.get_first_value("PRAGMA data_version")
      if @version != version
        @store.clear
        @version = version
      end
      [ @database, @namespace, @version ]
    end

  INSTANCE = new
end
