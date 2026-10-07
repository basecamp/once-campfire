module Message::Broadcasts
  def broadcast_create
    broadcast_append_to room, :messages, target: [ room, :messages ]
    broadcast_unread_room_later
  end

  def broadcast_remove
    broadcast_remove_to room, :messages
  end

  # Fanned out to the room's members rather than published on one global stream, so
  # that the timing of activity in a room only reaches people who are in it. Of those,
  # only the ones who still have it unread or are in it now: by the time this runs,
  # someone may have opened the room and moved on, and would see it marked unread again.
  def broadcast_unread_room
    payload = ActiveSupport::JSON.encode(roomId: room.id, at: created_at.to_fs(:epoch))

    room.memberships.unread.or(room.memberships.connected).pluck(:user_id).each do |user_id|
      ActionCable.server.broadcast UnreadRoomsChannel.stream_name_for(user_id), payload, coder: nil
    end
  end

  private
    # The fanout is one publish per member, which in a big room takes far longer than the
    # rest of posting a message, so it runs in a job rather than while the poster waits.
    def broadcast_unread_room_later
      Message::BroadcastUnreadRoomJob.perform_later(self)
    end
end
