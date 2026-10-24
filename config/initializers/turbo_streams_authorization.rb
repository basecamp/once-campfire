# Prepended as the channel loads, instead of loading Action Cable at boot. The
# channel is never reloaded but the guard is, so each reload prepends the new copy.
Rails.autoloaders.once.on_load("Turbo::StreamsChannel") do |channel|
  channel.prepend RoomStreamsAreAuthorized
end

Rails.application.config.after_initialize do |app|
  app.reloader.to_prepare { Turbo::StreamsChannel.prepend RoomStreamsAreAuthorized }
end
