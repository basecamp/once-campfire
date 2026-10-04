class Users::SidebarsController < ApplicationController
  DIRECT_PLACEHOLDERS = 20

  def show
    @direct_memberships, @other_memberships = Current.user.memberships.visible.with_ordered_room.partition { |membership| membership.room.direct? }
    @direct_memberships = @direct_memberships.sort_by { |membership| membership.room.updated_at }.reverse

    @direct_placeholder_users = find_direct_placeholder_users
  end

  private
    def find_direct_placeholder_users
      exclude_user_ids = user_ids_already_in_direct_rooms_with_current_user.including(Current.user.id)
      User.active.where.not(id: exclude_user_ids).order(:created_at).limit([ DIRECT_PLACEHOLDERS - exclude_user_ids.count, 0 ].max)
    end

    def user_ids_already_in_direct_rooms_with_current_user
      Membership.where(room_id: Current.user.rooms.directs.pluck(:id)).pluck(:user_id).uniq
    end
end
