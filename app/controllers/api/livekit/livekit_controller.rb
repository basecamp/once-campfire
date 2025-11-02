module Api
  module Livekit
    class LivekitController < ApplicationController
      def token
        room_id = params.require(:room_id)
        room = Current.user.rooms.find_by(id: room_id)

        unless room
          return render json: { error: "Room not found or inaccessible" }, status: :not_found
        end

        unless Rails.configuration.x.livekit.url.present? &&
               Rails.configuration.x.livekit.api_key.present? &&
               Rails.configuration.x.livekit.api_secret.present?
          return render json: { error: "LiveKit not configured" }, status: :service_unavailable
        end

        livekit_room_name = "room-#{room.id}"
        participant_identity = Current.user.id.to_s
        participant_name = Current.user.name

        access_token = generate_access_token(
          room_name: livekit_room_name,
          participant_identity: participant_identity,
          participant_name: participant_name
        )

        render json: {
          token: access_token,
          url: Rails.configuration.x.livekit.url,
          room_name: livekit_room_name,
          avatar_url: fresh_user_avatar_path(Current.user)
        }
      end

      def participant_avatar
        room_id = params.require(:room_id)
        user_id = params.require(:user_id)
        
        room = Current.user.rooms.find_by(id: room_id)
        unless room
          return render json: { error: "Room not found" }, status: :not_found
        end
        
        # Ensure user is in the same room
        user = room.users.find_by(id: user_id)
        unless user
          return render json: { error: "User not found in room" }, status: :not_found
        end
        
        render json: {
          avatar_url: fresh_user_avatar_path(user)
        }
      end

      private
        def generate_access_token(room_name:, participant_identity:, participant_name:)
          require "jwt"

          api_key = Rails.configuration.x.livekit.api_key
          api_secret = Rails.configuration.x.livekit.api_secret

          now = Time.now.to_i
          expires = now + (6 * 60 * 60) # 6 hours

          claims = {
            iss: api_key,
            sub: participant_identity,
            iat: now,
            exp: expires,
            video: {
              room: room_name,
              roomJoin: true,
              canPublish: true,
              canSubscribe: true,
              canPublishData: true
            }
          }

          claims[:name] = participant_name if participant_name.present?

          JWT.encode(claims, api_secret, "HS256")
        end
    end
  end
end

