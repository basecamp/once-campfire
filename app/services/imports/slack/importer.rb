module Imports
  module Slack
    class Importer
      attr_reader :path, :creator, :export_reader, :stats

      def initialize(path:, creator:)
        @path = Pathname.new(path)
        @creator = creator
        @export_reader = Imports::Slack::ExportReader.new(path)
        @stats = {
          users_created: 0,
          users_updated: 0,
          rooms_created: 0,
          messages_created: 0,
          messages_skipped: 0,
          errors: []
        }
      end

      def run
        ActiveRecord::Base.transaction do
          Current.importing = true
          
          Rails.logger.info "Starting Slack import from #{path}"
          
          user_mapping = upsert_users
          channel_mapping = upsert_rooms_and_memberships(user_mapping)
          import_messages(channel_mapping, user_mapping)
          
          Rails.logger.info "Slack import completed. Stats: #{stats}"
          stats
        ensure
          Current.importing = false
        end
      end

      private

      def upsert_users
        user_mapping = {}
        
        export_reader.users.each do |slack_user|
          next if slack_user["deleted"] || slack_user["is_bot"]
          
          name = Normalizer.normalize_user_name(slack_user)
          email = Normalizer.normalize_user_email(slack_user)
          
          # Find existing user by email or create new one
          user = if email.present?
            User.find_by(email_address: email) || 
            User.create!(
              name: name,
              email_address: email,
              password_digest: "", # Disabled validations allow this
              active: true
            ).tap { @stats[:users_created] += 1 }
          else
            # If no email, try to find by name or create new
            existing = User.find_by(name: name, active: true)
            if existing
              @stats[:users_updated] += 1
              existing
            else
              User.create!(
                name: name,
                email_address: nil,
                password_digest: "",
                active: true
              ).tap { @stats[:users_created] += 1 }
            end
          end
          
          user_mapping[slack_user["id"]] = user
        rescue ActiveRecord::RecordInvalid => e
          @stats[:errors] << "User creation failed for #{name}: #{e.message}"
          Rails.logger.warn "Failed to create user #{name}: #{e.message}"
        end
        
        user_mapping
      end

      def upsert_rooms_and_memberships(user_mapping)
        channel_mapping = {}
        
        export_reader.channels.each do |slack_channel|
          next if slack_channel["is_archived"]
          
          room_name = Normalizer.normalize_room_name(slack_channel)
          
          # Handle different room types
          room_class = case slack_channel["type"]
          when "channel", "public_channel"
            Rooms::Open
          when "group", "private_channel"
            Rooms::Closed
          when "im"
            room_name = derive_direct_message_name(slack_channel, user_mapping)
            Rooms::Direct
          when "mpim"
            Rooms::Closed # Multi-person DM as closed room
          else
            Room # Default to base Room
          end
          
          # Create or find room
          room = room_class.find_by(name: room_name) ||
                 room_class.create!(
                   name: room_name,
                   creator: creator
                 ).tap { @stats[:rooms_created] += 1 }
          
          # Create memberships for channel members
          if slack_channel["members"].present?
            slack_channel["members"].each do |slack_user_id|
              next unless user_mapping[slack_user_id]
              
              user = user_mapping[slack_user_id]
              unless room.users.include?(user)
                room.memberships.create!(
                  user: user,
                  involvement: room.default_involvement
                )
              end
            end
          end
          
          channel_mapping[slack_channel["id"]] = room
        rescue ActiveRecord::RecordInvalid => e
          @stats[:errors] << "Room creation failed for #{room_name}: #{e.message}"
          Rails.logger.warn "Failed to create room #{room_name}: #{e.message}"
        end
        
        channel_mapping
      end

      def import_messages(channel_mapping, user_mapping)
        export_reader.all_channels_with_messages.each do |channel_data|
          room = channel_mapping[channel_data["id"]]
          next unless room
          
          channel_data["messages"].each do |slack_message|
            import_single_message(slack_message, room, user_mapping, channel_data["id"])
          end
        end
      end

      def import_single_message(slack_message, room, user_mapping, channel_id)
        # Skip system messages and bot messages for v0
        return if slack_message["subtype"].present?
        return if slack_message["user"].blank?
        
        creator_user = user_mapping[slack_message["user"]]
        return unless creator_user
        
        client_msg_id = Normalizer.client_message_id(slack_message, channel_id)
        
        # Check if message already exists (idempotency)
        if Message.exists?(room: room, client_message_id: client_msg_id)
          @stats[:messages_skipped] += 1
          return
        end
        
        body = Normalizer.normalize_message_body(slack_message, user_mapping)
        created_at = Normalizer.slack_timestamp_to_time(slack_message["ts"])
        
        Message.create!(
          room: room,
          creator: creator_user,
          client_message_id: client_msg_id,
          body: body,
          created_at: created_at,
          updated_at: created_at
        )
        
        @stats[:messages_created] += 1
        
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "Message creation failed in #{room.name} at #{slack_message['ts']}: #{e.message}"
        Rails.logger.warn "Failed to create message in #{room.name}: #{e.message}"
      rescue => e
        @stats[:errors] << "Unexpected error in #{room.name} at #{slack_message['ts']}: #{e.message}"
        Rails.logger.error "Unexpected error importing message: #{e.message}"
      end

      def derive_direct_message_name(slack_channel, user_mapping)
        # For direct messages, create a name based on the users
        if slack_channel["members"].present? && slack_channel["members"].size == 2
          user_names = slack_channel["members"].map do |slack_user_id|
            user_mapping[slack_user_id]&.name || "unknown"
          end.sort
          "dm-#{user_names.join('-')}"
        else
          "dm-#{slack_channel['id']}"
        end
      end
    end
  end
end