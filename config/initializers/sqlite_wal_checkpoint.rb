Rails.application.config.after_initialize do
  next unless Rails.application.config.x.sqlite_wal_checkpoint

  SqliteWalCheckpoint.start
end
