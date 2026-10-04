class Message::BroadcastUnreadRoomJob < ApplicationJob
  def perform(message)
    message.broadcast_unread_room
  end
end
