module Internal
  module Backlit
    class RoomsController < BaseController
      def create
        room = find_or_create_room!
        render json: room_payload(room), status: :created
      end

      def update
        room = find_room!
        room.update!(name: params[:name]) if params[:name].present?
        render json: room_payload(room)
      end

      def archive
        room = find_room!
        Room.transaction do
          room.update!(archived_at: Time.current)
          room.memberships.delete_all
        end
        render json: room_payload(room.reload)
      end

      def memberships
        room = find_room!
        users = Array(params[:subs]).map { |sub| find_user_by_sub!(sub) }
        room.memberships.grant_to(users)
        render json: { room_id: room.id, granted: users.map(&:sso_uid) }
      end

      def revoke_memberships
        room = find_room!
        users = Array(params[:subs]).map { |sub| find_user_by_sub!(sub) }
        room.memberships.revoke_from(users)
        render json: { room_id: room.id, revoked: users.map(&:sso_uid) }
      end

      private
        def find_or_create_room!
          project_id = params.require(:backlit_project_id).to_s
          kind = params.require(:backlit_kind).to_s
          name = params.require(:name).to_s

          room = Room.find_by(backlit_project_id: project_id, backlit_kind: kind)
          return room if room

          creator = provisioning_bot!
          Rooms::Closed.create_for(
            { name: name, backlit_project_id: project_id, backlit_kind: kind, creator: creator },
            users: [ creator ]
          )
        end

        def find_room!
          if params[:id].present?
            Room.find(params[:id])
          else
            Room.find_by!(
              backlit_project_id: params.require(:backlit_project_id),
              backlit_kind: params.require(:backlit_kind)
            )
          end
        end

        def provisioning_bot!
          User.find_by(role: :bot, name: "Backlit Sync") ||
            User.create_bot!(name: "Backlit Sync")
        end

        def room_payload(room)
          {
            id: room.id,
            name: room.name,
            backlit_project_id: room.backlit_project_id,
            backlit_kind: room.backlit_kind,
            archived_at: room.archived_at
          }
        end
    end
  end
end
