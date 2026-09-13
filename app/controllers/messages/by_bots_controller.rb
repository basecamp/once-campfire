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
    render :show, status: :created, location: message_url(@message)
  end

  def destroy
    super
    head :no_content
  end

  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { errors: error.record.errors.to_hash }, status: :unprocessable_content
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
      headers["X-Total-Count"] = @room.messages.count.to_s

      if next_page = next_page_params
        headers["Link"] = %(<#{room_bot_messages_url(@room, params[:bot_key], **next_page)}>; rel="next")
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

    BOT_ACTION_FIELDS = %i[ label value url style background_color text_color icon emoji icon_position icon_only disabled ]

    def message_params
      if params[:attachment]
        params.permit(:attachment)
      elsif request.media_type == "application/json"
        json_message_params
      else
        { body: raw_request_body }
      end
    end

    def json_message_params
      params.permit(:body).to_h.tap do |attributes|
        attributes["bot_actions"] = bot_actions_attribute if params.key?(:actions)
        attributes["bot_action_selection_mode"] = params[:selection_mode] if params.key?(:selection_mode)
      end
    end

    # Permitting the whole array would quietly drop anything that isn't a hash of
    # scalars, so a malformed action would look like a successful edit. Filter each
    # entry instead and let anything else through to fail validation.
    def bot_actions_attribute
      return params[:actions] unless params[:actions].is_a?(Array)

      params[:actions].map do |action|
        action.is_a?(ActionController::Parameters) ? action.permit(*BOT_ACTION_FIELDS).to_h : action
      end
    end
end
