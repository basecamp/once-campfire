require File.expand_path("../config/environment", File.dirname(__FILE__))

# Puma can serve each request in a thread from an internal thread pool.
# The `threads` method setting takes two numbers: a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma. Default is set to 5 threads for minimum
# and maximum; this matches the default thread size of Active Record.
#
max_threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { max_threads_count }
threads min_threads_count, max_threads_count

# Specifies the `worker_timeout` threshold that Puma will use to wait before
# terminating a worker in development environments.
#
worker_timeout 3600 if ENV.fetch("RAILS_ENV", "development") == "development"

# Bind http listener.
PORT=ENV.fetch("PORT", 3000)
bind "tcp://0.0.0.0:#{PORT}"

# Specifies the `environment` that Puma will run in.
#
environment ENV.fetch("RAILS_ENV") { "development" }

# Specifies the `pidfile` that Puma will use.
pidfile ENV.fetch("PIDFILE") { "tmp/pids/server.pid" }

# Specifies the number of `workers` to boot in clustered mode.
# Workers are forked web server processes. If using threads and workers together
# the concurrency of the application would be max `threads` * `workers`.
# Workers do not work on JRuby or Windows (both of which do not support
# processes).
#
worker_count = (Concurrent.processor_count * 0.666).ceil
# Keep the raw setting: WEB_CONCURRENCY=auto must not be coerced with to_i (that
# is 0 and would look like single-process mode while Puma still forks workers).
configured_workers = ENV.fetch("WEB_CONCURRENCY") { worker_count }
workers configured_workers

ENV["JOB_CONCURRENCY"] ||= worker_count.to_s

# Use the `preload_app!` method when specifying a `workers` number.
# This directive tells Puma to first boot the application and load code
# before forking the application. This takes advantage of Copy On Write
# process behavior so workers use less memory.
#
# preload_app!

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Reset all membership connections
Membership.disconnect_all

# Only the literal 0 is single-process. "auto" and positive counts fork workers;
# those must start the checkpointer after boot so a surviving worker can take
# the lock if the previous leader exits.
if SqliteWalCheckpoint.single_puma_process?(configured_workers)
  SqliteWalCheckpoint.start
else
  on_worker_boot { SqliteWalCheckpoint.start }
end

Signal.trap :SIGPROF do
  Thread.list.each do |t|
    puts t
    puts t.backtrace
    puts
  end
end
