# schema.rb cannot dump SQLite triggers. Reinstall after loads, and re-append
# Room::MessagesCount.install! after dumps so the call is not lost.
namespace :room_messages_count do
  task ensure: :environment do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      next unless connection.adapter_name.match?(/sqlite/i)

      Room::MessagesCount.ensure!(connection)
    end
  end

  task append_schema_install: :environment do
    schema = Rails.root.join("db/schema.rb")
    contents = schema.read
    marker = "Room::MessagesCount.install!"
    next if contents.include?(marker)

    contents.sub!(/\nend\n?\z/, <<~RUBY)

      # SQLite triggers are not dumped by schema.rb; keep rooms.messages_count honest after schema:load.
      #{marker}
    end
    RUBY
    schema.write(contents)
  end
end

{
  "db:schema:load" => "room_messages_count:ensure",
  "db:test:load_schema" => "room_messages_count:ensure",
  "db:schema:dump" => "room_messages_count:append_schema_install"
}.each do |task_name, enhancement|
  next unless Rake::Task.task_defined?(task_name)

  Rake::Task[task_name].enhance do
    Rake::Task[enhancement].invoke
  end
end
