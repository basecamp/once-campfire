module Imports
  module Slack
    class Normalizer
      def self.slack_timestamp_to_time(ts)
        return nil unless ts
        Time.at(ts.to_f)
      end

      def self.normalize_user_name(slack_user)
        return "Unknown User" unless slack_user

        slack_user.dig("profile", "real_name").presence ||
          slack_user["real_name"].presence ||
          slack_user["name"].presence ||
          "Unknown User"
      end

      def self.normalize_user_email(slack_user)
        return nil unless slack_user
        slack_user.dig("profile", "email").presence
      end

      def self.normalize_room_name(slack_channel)
        return "Unknown Channel" unless slack_channel

        case slack_channel["type"]
        when "channel", "public_channel"
          slack_channel["name"] || "public-channel"
        when "group", "private_channel"
          slack_channel["name"] || "private-channel"
        when "im"
          # For direct messages, we'll need to derive a name later
          nil
        when "mpim"
          # For multi-person direct messages
          slack_channel["name"] || "group-dm"
        else
          slack_channel["name"] || "unknown-channel"
        end
      end

      def self.normalize_message_body(slack_message, user_mapping = {})
        return "" unless slack_message

        text = slack_message["text"].to_s
        
        # Convert basic Slack markdown to HTML
        text = convert_slack_markdown(text)
        
        # Convert user mentions
        text = convert_user_mentions(text, user_mapping)
        
        # Append file links if present
        if slack_message["files"].present?
          file_links = slack_message["files"].map do |file|
            file_url = file["url_private"] || file["permalink"] || "#"
            file_name = file["name"] || "Attachment"
            "\n<a href=\"#{file_url}\">📎 #{file_name}</a>"
          end
          text += file_links.join
        end

        # Add thread indicator if this is a threaded message
        if slack_message["thread_ts"] && slack_message["thread_ts"] != slack_message["ts"]
          text = "(thread) #{text}"
        end

        text
      end

      def self.client_message_id(slack_message, channel_id)
        slack_message["client_msg_id"].presence || 
          "slack:#{channel_id}:#{slack_message['ts']}"
      end

      private

      def self.convert_slack_markdown(text)
        # Convert bold: *text* -> <strong>text</strong>
        text = text.gsub(/\*([^*]+)\*/, '<strong>\1</strong>')
        
        # Convert italic: _text_ -> <em>text</em>
        text = text.gsub(/_([^_]+)_/, '<em>\1</em>')
        
        # Convert code: `text` -> <code>text</code>
        text = text.gsub(/`([^`]+)`/, '<code>\1</code>')
        
        # Convert links: <http://example.com|text> -> <a href="http://example.com">text</a>
        text = text.gsub(/<([^|>]+)\|([^>]+)>/, '<a href="\1">\2</a>')
        
        # Convert simple links: <http://example.com> -> <a href="http://example.com">http://example.com</a>
        text = text.gsub(/<(https?:\/\/[^>]+)>/, '<a href="\1">\1</a>')
        
        text
      end

      def self.convert_user_mentions(text, user_mapping)
        # Convert <@U123456> to @username or user name
        text.gsub(/<@([^>]+)>/) do |match|
          slack_user_id = $1
          if user_mapping[slack_user_id]
            "@#{user_mapping[slack_user_id].name}"
          else
            "@unknown-user"
          end
        end
      end
    end
  end
end