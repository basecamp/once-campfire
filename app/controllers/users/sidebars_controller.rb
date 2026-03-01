class Users::SidebarsController < ApplicationController
  DIRECT_PLACEHOLDERS = 20

  def show
    all_memberships     = Current.user.memberships.visible.with_ordered_room.includes(room: :users)
    @direct_memberships = extract_direct_memberships(all_memberships)
    @other_memberships  = all_memberships.reject { |membership| membership.room.direct? }

    @direct_placeholder_users = find_direct_placeholder_users
  end

  private
    def extract_direct_memberships(all_memberships)
      all_memberships
        .select { |membership| membership.room.direct? && direct_room_visible_for?(membership.room) }
        .sort_by { |membership| membership.room.updated_at }
        .reverse
    end

    def direct_room_visible_for?(room)
      room.users.all? { |user| user == Current.user || user.active? }
    end

    def find_direct_placeholder_users
      exclude_user_ids = user_ids_already_in_direct_rooms_with_current_user.including(Current.user.id)
      User.active.where.not(id: exclude_user_ids).order(:created_at).limit(DIRECT_PLACEHOLDERS - exclude_user_ids.count)
    end

    def user_ids_already_in_direct_rooms_with_current_user
      Membership.where(room_id: Current.user.rooms.directs.pluck(:id)).pluck(:user_id).uniq
    end
end
