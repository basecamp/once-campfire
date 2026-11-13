# schema.rb cannot dump SQLite triggers. Cover existing DBs that lost them on
# boot where the app is eager loaded, so Room is loaded already; elsewhere,
# schema loads and migrations repair them (lib/tasks/room_messages_count.rake).
Rails.application.config.after_initialize do
  Room::MessagesCount.ensure! if Rails.configuration.eager_load
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
end
