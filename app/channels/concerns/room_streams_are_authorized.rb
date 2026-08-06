# Prepended onto Turbo::StreamsChannel. The subscriber names the channel it wants, so
# authorizing room messages only in RoomMessagesChannel would leave the stock channel as
# a way around it: same signed stream name, no membership check. Turn those names away
# here and RoomMessagesChannel becomes the only door.
module RoomStreamsAreAuthorized
  def subscribed
    if RoomMessagesChannel.guarded_stream?(verified_stream_name_from_params)
      reject
    else
      super
    end
  end
end
