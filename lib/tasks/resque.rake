task "resque:setup" do
  require_relative "../../config/environment"
end

task "resque:pool:setup" do
  ActiveRecord::Base.connection.disconnect!

  Resque::Pool.after_prefork do |job|
    ActiveRecord::Base.establish_connection
    Resque.redis.client.close
    SqliteWalCheckpoint.start
  end
end
