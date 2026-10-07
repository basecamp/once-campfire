# schema.rb cannot dump SQLite triggers — reinstall after schema loads.
namespace :room_messages_count do
  task ensure: :environment do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      Room::MessagesCount.ensure!(connection)
    end
  end
end

%w[db:schema:load db:test:load_schema].each do |task_name|
  next unless Rake::Task.task_defined?(task_name)

  Rake::Task[task_name].enhance do
    Rake::Task["room_messages_count:ensure"].invoke
  end
end
