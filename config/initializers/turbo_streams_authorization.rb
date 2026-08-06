Rails.application.config.to_prepare do
  Turbo::StreamsChannel.prepend RoomStreamsAreAuthorized
end
