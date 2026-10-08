module RoomScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_room
  end

  private
    def set_room
      @membership, @room = RecordCache.fetch([ "membership", Current.user.id, params[:room_id] ], read_record_cache_version) do
        membership = Current.user.memberships.find_by!(room_id: params[:room_id])
        [ membership, membership.room ]
      end
      @membership.room = @room
    end
end
