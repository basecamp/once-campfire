require "rbconfig"

begin
  require "campfire_sqlite_native/campfire_sqlite_native"
rescue LoadError
  # Bundler does not compile extensions for path gems.
  require "rubygems/ext"
  spec = Gem.loaded_specs.fetch("campfire_sqlite_native")
  Gem::Ext::Builder.new(spec).build_extensions
  require "campfire_sqlite_native/campfire_sqlite_native"
end

module CampfireSQLiteNative
  MUTEX = Mutex.new
  REGISTRATIONS = ObjectSpace::WeakMap.new
  EXTENSION_PATH = begin
    extension_name = "campfire_sqlite_native.#{RbConfig::CONFIG.fetch("DLEXT")}"
    loaded = $LOADED_FEATURES.reverse.find { File.basename(_1) == extension_name }
    raise LoadError, "campfire_sqlite_native extension path cannot be identified" unless loaded

    File.realpath(loaded).freeze
  end

  class << self
    def main_database_moved?(database)
      MUTEX.synchronize do
        native_main_database_moved?(registration_for(database))
      end
    end

    def main_database_descriptor(database)
      MUTEX.synchronize do
        native_main_database_descriptor(registration_for(database))
      end
    end

    private
      def registration_for(database)
        REGISTRATIONS[database] ||= begin
          begin
            database.enable_load_extension(true)
            database.load_extension(EXTENSION_PATH)
            take_registration
          ensure
            database.enable_load_extension(false)
          end
        end
      end

      private :native_main_database_descriptor, :native_main_database_moved?, :take_registration
  end
end
