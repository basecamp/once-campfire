# Loaded from lib/rails_ext (autoload_lib ignore list) so reloads do not orphan
# the contender thread. Non-test processes start here; forking servers stop
# before fork and start again in the child.
require Rails.root.join("lib/rails_ext/sqlite_wal_checkpoint")

Rails.application.config.after_initialize do
  SqliteWalCheckpoint.start unless Rails.env.test?
end
