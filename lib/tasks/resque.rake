task "resque:setup" do
  require_relative "../../config/environment"
end

task "resque:pool:setup" do
  ActiveRecord::Base.connection.disconnect!
  # Initializer may have started a contender in the pool master; drop it before
  # workers fork so they do not inherit the flock.
  SqliteWalCheckpoint.stop

  Resque::Pool.after_prefork do |job|
    ActiveRecord::Base.establish_connection
    Resque.redis.client.close
    SqliteWalCheckpoint.start
  end
end
