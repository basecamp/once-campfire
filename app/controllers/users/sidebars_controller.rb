class Users::SidebarsController < ApplicationController
  DIRECT_PLACEHOLDERS = 20

  def show
    all_memberships     = Current.user.memberships.visible.with_ordered_room
    @direct_memberships = extract_direct_memberships(all_memberships)
    @other_memberships  = all_memberships.without(@direct_memberships)
    direct_user_ids = user_ids_already_in_direct_rooms_with_current_user
    @direct_online_user_lookup = Membership.online_user_lookup(direct_user_ids)

    @direct_placeholder_users = find_direct_placeholder_users(direct_user_ids)
  end

  private
    def extract_direct_memberships(all_memberships)
      all_memberships.select { |m| m.room.direct? }.sort_by { |m| m.room.updated_at }.reverse
    end

    def find_direct_placeholder_users(direct_user_ids)
      exclude_user_ids = direct_user_ids.including(Current.user.id)
      User.active.where.not(id: exclude_user_ids).order(:created_at).limit([ DIRECT_PLACEHOLDERS - exclude_user_ids.count, 0 ].max)
    end

    def user_ids_already_in_direct_rooms_with_current_user
      Membership.where(room_id: Current.user.rooms.directs.pluck(:id)).pluck(:user_id).uniq
    end
end
