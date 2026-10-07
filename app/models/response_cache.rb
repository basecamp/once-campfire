require "sqlite3"

# A read-only observer sees commits from every writer, including other runtimes.
# PRAGMA data_version can only be compared on the same persistent connection.
class ResponseCache
  MAX_ENTRY_BYTES = 1.megabyte
  MAX_KEY_BYTES = 2.kilobytes

  def self.instance
    @instance ||= new
  end

  def initialize
    @mutex = Mutex.new
    @entries = {}
    @bytes = 0
  end

  def budget
    [ ENV.fetch("CAMPFIRE_RESPONSE_CACHE_MB", "64").to_i, 0 ].max.megabytes
  end

  def version
    @mutex.synchronize { current_version }
  rescue SQLite3::Exception
    clear
    nil
  end

  def read(key, version)
    @mutex.synchronize do
      @entries[key]&.first if current_version == version
    end
  rescue SQLite3::Exception
    clear
    nil
  end

  def write(key, version, entry)
    size = key.bytesize + entry[:body].bytesize + entry[:headers].sum { |name, value| name.bytesize + value.bytesize } + 256
    return if key.bytesize > MAX_KEY_BYTES || size > [ budget, MAX_ENTRY_BYTES ].min

    @mutex.synchronize do
      return unless current_version == version
      return if @entries.key?(key)

      while @entries.any? && @bytes + size > budget
        _, (_, removed_size) = @entries.shift
        @bytes -= removed_size
      end
      @entries[key] = [ entry, size ]
      @bytes += size
    end
  rescue SQLite3::Exception
    clear
  end

  def clear
    @mutex.synchronize do
      @entries.clear
      @bytes = 0
      @observer&.close
      @observer = @database = @version = nil
    end
  end

  private
    def current_version
      database = File.expand_path(ActiveRecord::Base.connection_db_config.database)
      if @database != database || !@observer
        @entries.clear
        @bytes = 0
        @observer&.close
        @observer = nil
        @observer = SQLite3::Database.new(database, readonly: true)
        @database = database
        @namespace = SecureRandom.hex(16)
        @version = nil
      end

      version = @observer.get_first_value("PRAGMA data_version")
      if @version != version
        @entries.clear
        @bytes = 0
        @version = version
      end
      [ @database, @namespace, @version ]
    end
end
