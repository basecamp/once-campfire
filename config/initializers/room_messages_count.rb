# schema.rb cannot dump SQLite triggers. Reinstall after boot when an existing DB
# is missing them (db:schema:load / test schema load also call ensure! via rake).
Rails.application.config.after_initialize do
  ActiveRecord::Base.connection_pool.with_connection do |connection|
    next unless connection.adapter_name.match?(/sqlite/i)

    Room::MessagesCount.ensure!(connection)
  end
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
end
