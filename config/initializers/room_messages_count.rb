# schema.rb cannot dump SQLite triggers. Cover existing DBs that lost them.
Rails.application.config.after_initialize do
  Room::MessagesCount.ensure!
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
end
