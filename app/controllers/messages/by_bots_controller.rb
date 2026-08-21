class Messages::ByBotsController < MessagesController
  allow_bot_access only: :create
  before_action :require_bot_key_authentication, only: :create

  def create
    super
    return if performed?

    head :created, location: room_at_message_url(@room, @message)
  end

  private
    def require_bot_key_authentication
      head :forbidden unless authenticated_by.bot_key?
    end

    def message_params
      if params[:attachment]
        params.permit(:attachment).merge(origin: Message::ORIGIN_BOT_API)
      else
        reading(request.body) { |body| { body:, origin: Message::ORIGIN_BOT_API } }
      end
    end

    def reading(io)
      io.rewind
      ContentLimits.verify! request.content_length.to_i,
        maximum: ContentLimits::MESSAGE_BODY_BYTES, description: "message body"
      body = ContentLimits.read(
        io, maximum: ContentLimits::MESSAGE_BODY_BYTES, description: "message body"
      )
      yield body.force_encoding("UTF-8")
    ensure
      io.rewind
    end
end
