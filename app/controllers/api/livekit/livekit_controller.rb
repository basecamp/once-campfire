module Api
  module Livekit
    class LivekitController < ApplicationController
      def token
        begin
          # Validate inputs
          room_id = validate_room_id(params[:room_id])
          mode = validate_mode(params[:mode])

          room = Current.user.rooms.find_by(id: room_id)
          unless room
            return render json: { error: "Room not found" }, status: :not_found
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
            participant_name: participant_name,
            mode: mode
          )

          render json: {
            token: access_token,
            url: Rails.configuration.x.livekit.url,
            room_name: livekit_room_name,
            avatar_url: fresh_user_avatar_path(Current.user)
          }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :bad_request
        rescue JWT::EncodeError => e
          Rails.logger.error("Failed to encode JWT token: #{e.message}")
          render json: { error: "Failed to generate access token" }, status: :internal_server_error
        rescue StandardError => e
          Rails.logger.error("Token generation failed: #{e.message}")
          render json: { error: "An error occurred generating token" }, status: :internal_server_error
        end
      end

      def participant_avatar
        begin
          # Validate inputs
          room_id = validate_room_id(params[:room_id])
          user_id = validate_user_id(params[:user_id])

          room = Current.user.rooms.find_by(id: room_id)
          unless room
            return render json: { error: "Room not found" }, status: :not_found
          end

          # Ensure user is in the same room
          user = room.users.find_by(id: user_id)
          unless user
            return render json: { error: "User not found in room" }, status: :not_found
          end

          # ADDED: Cache for 1 hour to reduce API calls
          expires_in 1.hour, public: false

          render json: {
            avatar_url: fresh_user_avatar_path(user),
            initials: user.initials,
            name: user.name
          }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :bad_request
        end
      end

      private
        def validate_room_id(value)
          raise ArgumentError, "room_id is required" if value.blank?
          id = value.to_i
          raise ArgumentError, "Invalid room_id" if id <= 0
          id
        end

        def validate_user_id(value)
          raise ArgumentError, "user_id is required" if value.blank?
          id = value.to_i
          raise ArgumentError, "Invalid user_id" if id <= 0
          id
        end

        def validate_mode(value)
          mode = value.to_s
          valid_modes = ["", "observe"]
          raise ArgumentError, "Invalid mode: #{mode}" unless valid_modes.include?(mode)
          mode
        end

        def generate_access_token(room_name:, participant_identity:, participant_name:, mode:)
          require "jwt"

          api_key = Rails.configuration.x.livekit.api_key
          api_secret = Rails.configuration.x.livekit.api_secret

          now = Time.now.to_i
          expires = now + (6 * 60 * 60) # 6 hours

          publish_enabled = mode != "observe"
          claims = {
            iss: api_key,
            sub: participant_identity,
            iat: now,
            exp: expires,
            video: {
              room: room_name,
              roomJoin: true,
              canPublish: publish_enabled,
              canSubscribe: true,
              canPublishData: publish_enabled
            }
          }

          claims[:name] = participant_name if participant_name.present?

          JWT.encode(claims, api_secret, "HS256")
        end
    end
  end
end
