ActiveSupport.on_load(:action_text_content) do
  class ActionText::Attachment
    class << self
      def from_node(node, attachable = nil)
        new(node, attachable || ActionText::Attachment::OpengraphEmbed.from_node(node) || attachable_from_possibly_expired_sgid(node["sgid"]) || ActionText::Attachable.from_node(node))
      end

      private
        # Our @mentions use ActionText attachments, which are signed. If someone rotates SECRET_KEY_BASE, the existing attachments become invalid.
        # This allows ignoring invalid signatures for User attachments in ActionText.
        ATTACHABLES_PERMITTED_WITH_INVALID_SIGNATURES = %w[ User ]

        def attachable_from_possibly_expired_sgid(sgid)
          if message = sgid&.split("--")&.first
            encoded_message = JSON.parse(decode_base64(message))

            decoded_gid = if data = encoded_message.dig("_rails", "data")
              data
            elsif data = encoded_message.dig("_rails", "message")
              # Rails 7 used an older format of GID that serialized the payload using Marshall
              # Since we intentionally skip signature verification, we can't safely unmarshal the data
              # To work around this, we manually extract the GID from the marshaled data
              decode_base64(data).match(%r{(gid://campfire/[^/]+/\d+)})&.to_s
            else
              nil
            end

            if model = GlobalID.find(decoded_gid)
              model.model_name.to_s.in?(ATTACHABLES_PERMITTED_WITH_INVALID_SIGNATURES) ? model : nil
            end
          end
        rescue ActiveRecord::RecordNotFound
          nil
        end

        def decode_base64(message)
          Base64.strict_decode64(message)
        rescue => _e
          Base64.urlsafe_decode64(message)
        end
    end
  end
end
