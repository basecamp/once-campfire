class PresenceChannel < RoomChannel
  on_subscribe   :present, unless: :subscription_rejected?
  on_unsubscribe :absent,  unless: :subscription_rejected?

  def present
    @presence = membership&.present(replacing: @presence)

    if @presence
      broadcast_read_room
    else
      reject
    end
  end

  def absent
    membership&.absent @presence
    @presence = nil
  end

  def refresh
    if refreshed = membership&.refresh_presence(@presence)
      @presence = refreshed
    elsif @presence
      @presence = nil
      connection.close reason: "Presence expired", reconnect: true
    end
  end

  private
    def membership
      @room.memberships.find_by(user: current_user)
    end

    def broadcast_read_room
      ActionCable.server.broadcast "user_#{current_user.id}_reads", { room_id: membership.room_id }
    end
end
