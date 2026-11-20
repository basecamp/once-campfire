# Loaded from lib/rails_ext (autoload_lib ignore list) so reloads do not orphan
# the contender thread. Non-test processes start here; Puma/Resque stop before
# fork and start again in the child. The contender reads Active Record's
# database config, so it starts once Active Record has loaded, not before.
require Rails.root.join("lib/rails_ext/sqlite_wal_checkpoint")

Rails.application.config.after_initialize do
  ActiveSupport.on_load(:active_record) { SqliteWalCheckpoint.start } unless Rails.env.test?
end
