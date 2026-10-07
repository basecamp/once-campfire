# Start a checkpoint contender in console, runner, rake and other non-Puma writers.
# Puma skips this path: config/puma.rb and config/puma_dev.rb start after the
# correct process is chosen (worker boot vs single-process), so the master that
# only forks workers never holds the lock alone. Resque starts after_prefork.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  next if defined?(Puma::CLI)

  SqliteWalCheckpoint.start
end
