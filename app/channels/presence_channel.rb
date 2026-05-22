class PresenceChannel < RoomChannel
  on_subscribe   :present, unless: :subscription_rejected?
  on_unsubscribe :absent,  unless: :subscription_rejected?

  def present
    membership.present

    broadcast_presence(:present)
    broadcast_direct_room_presence
    broadcast_read_room
  end

  def absent
    membership.disconnected

    broadcast_presence(:absent)
    broadcast_direct_room_presence
  end

  def refresh
    membership.refresh_connection
  end

  private
    def membership
      @room.memberships.find_by(user: current_user)
    end

    def broadcast_presence(action)
      broadcast_to @room, action:, user: current_user_attributes
    end

    def broadcast_direct_room_presence
      direct_room_ids = direct_room_ids_for_current_user
      return if direct_room_ids.empty?

      direct_room_membership_scope = Membership.where(room_id: direct_room_ids)
      direct_room_memberships = direct_room_membership_scope.includes(:user, room: :users)
      direct_user_ids = direct_room_membership_scope.distinct.pluck(:user_id)
      online_user_lookup = Membership.online_user_lookup(direct_user_ids)

      direct_room_memberships.each do |room_membership|
        room_membership.broadcast_replace_to room_membership.user, :rooms,
          target: [ room_membership.room, :list ],
          partial: "users/sidebars/rooms/direct",
          locals: { membership: room_membership, online_user_lookup: online_user_lookup }
      end
    end

    def broadcast_read_room
      ActionCable.server.broadcast "user_#{current_user.id}_reads", { room_id: membership.room_id }
    end

    def current_user_attributes
      current_user.slice(:id, :name)
    end

    def direct_room_ids_for_current_user
      current_user.memberships
        .joins(:room)
        .merge(Room.directs)
        .distinct
        .pluck(:room_id)
    end
end
