class Messages::ByBotsController < MessagesController
  include RawRequestBody

  allow_bot_access only: %i[ index create update destroy ]

  before_action :set_room
  before_action :set_message, only: %i[ update destroy ]
  before_action :ensure_can_administer, only: %i[ update destroy ]
  before_action :ensure_body_or_attachment_present, only: :create

  def index
    @messages = find_paged_messages
    set_pagination_headers
  end

  def create
    super
    head :created, location: message_url(@message)
  end

  def destroy
    super
    head :no_content
  end

  private
    def set_room
      @room = Current.user.rooms.find_by(id: params[:room_id])

      head :not_found unless @room
    end

    def ensure_body_or_attachment_present
      if params[:attachment].blank? && raw_request_body.blank?
        head :unprocessable_content
      end
    end

    def set_pagination_headers
      headers["X-Total-Count"] = @room.messages_count.to_s

      if next_page = next_page_params
        headers["Link"] = %(<#{next_page_url(next_page)}>; rel="next")
      end
    end

    # Keep the key out of the link when it arrived in a header.
    def next_page_url(page)
      if bot_key = request.path_parameters[:bot_key]
        room_bot_messages_url(@room, bot_key, **page)
      else
        room_bot_api_messages_url(@room, **page)
      end
    end

    def next_page_params
      if @messages.any?
        if params[:after].present?
          { after: @messages.last.id } if @room.messages.after(@messages.last).exists?
        else
          { before: @messages.first.id } if @room.messages.before(@messages.first).exists?
        end
      end
    end

    def message_params
      if params[:attachment]
        params.permit(:attachment)
      else
        { body: raw_request_body }
      end
    end
end
