require File.expand_path("../config/environment", File.dirname(__FILE__))
require "puma_chunked_body_limit"

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
port = ENV.fetch("PORT", 3000)
bind_host = case ENV["CAMPFIRE_INTERNAL_TLS_PROXY"]
when "true" then "127.0.0.1"
when nil then "0.0.0.0"
else raise "CAMPFIRE_INTERNAL_TLS_PROXY must be exactly true when set"
end
bind "tcp://#{bind_host}:#{port}"
http_content_length_limit ContentLimits.request_body_bytes

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
worker_count = [ (Concurrent.available_processor_count * 0.666).ceil, 4 ].min
workers ENV.fetch("WEB_CONCURRENCY") { worker_count }
shutdown_timeout = Integer(ENV.fetch("CAMPFIRE_SHUTDOWN_TIMEOUT", "60"), 10)
raise "CAMPFIRE_SHUTDOWN_TIMEOUT must be positive" unless shutdown_timeout.positive?
worker_shutdown_timeout shutdown_timeout

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

Signal.trap :SIGPROF do
  Thread.list.each do |t|
    puts t
    puts t.backtrace
    puts
  end
end
