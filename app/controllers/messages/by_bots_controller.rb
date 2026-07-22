class Messages::ByBotsController < MessagesController
  allow_bot_access only: %i[ index create ]

  def index
    set_room
    @messages = find_paged_messages
    render json: messages_as_json(@messages)
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def create
    set_room
    @message = @room.messages.create_with_attachment!(message_params)
    @message.broadcast_create
    deliver_webhooks_to_bots
    head :created, location: message_url(@message)
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private
    def messages_as_json(messages)
      {
        room: {
          id: @room.id,
          name: @room.name
        },
        messages: messages.map { |m| message_as_json(m) },
        pagination: pagination_info(messages)
      }
    end

    def message_as_json(message)
      {
        id: message.id,
        body: {
          plain: message.plain_text_body,
          html: message.body&.body&.to_s
        },
        created_at: message.created_at.iso8601,
        creator: {
          id: message.creator.id,
          name: message.creator.name,
          is_bot: message.creator.bot?
        }
      }
    end

    def pagination_info(messages)
      return {} if messages.empty?
      {
        oldest_id: messages.last.id,
        newest_id: messages.first.id,
        has_more: messages.size == Message::PAGE_SIZE
      }
    end

    def message_params
      if params[:attachment]
        params.permit(:attachment)
      else
        reading(request.body) { |body| { body: body } }
      end
    end

    def reading(io)
      io.rewind
      yield io.read.force_encoding("UTF-8")
    ensure
      io.rewind
    end
end
