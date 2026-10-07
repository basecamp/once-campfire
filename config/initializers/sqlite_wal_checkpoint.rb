# Start a checkpoint contender in every non-test process. Puma and Resque pool
# stop before fork and start again in the child so the flock is never inherited.
Rails.application.config.after_initialize do
  SqliteWalCheckpoint.start unless Rails.env.test?
end
