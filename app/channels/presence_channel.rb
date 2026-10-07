class PresenceChannel < RoomChannel
  on_subscribe   :present, unless: :subscription_rejected?
  on_unsubscribe :absent,  unless: :subscription_rejected?

  def present
    membership.present

    broadcast_read_room
  end

  def absent
    membership.disconnected
  end

  def refresh
    membership.refresh_connection
  end

  private
    def membership
      @room.memberships.find_by(user: current_user)
    end

    def broadcast_read_room
      ActionCable.server.broadcast "user_#{current_user.id}_reads", { room_id: membership.room_id, at: Time.current.to_f }
    end
end
