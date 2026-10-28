# schema.rb cannot dump SQLite triggers. Cover existing DBs that lost them.
Rails.application.config.after_initialize do
  Message::PresentationVersion.ensure!
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
end
