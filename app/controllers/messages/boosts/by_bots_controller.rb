class Messages::Boosts::ByBotsController < Messages::BoostsController
  include RawRequestBody

  allow_bot_access only: %i[ create destroy ]
  skip_before_action :set_message, :set_boost

  before_action :require_bot_key_authentication
  before_action :set_message
  before_action :set_boost, only: :destroy
  before_action :ensure_content_present, only: :create

  def create
    @boost = Boost.create_by!(
      message: @message, actor: Current.user, attributes: boost_params, authenticated_bot_key:
    )

    broadcast_create
    render :show, status: :created
  end

  private
    def set_message
      if room = Current.user.rooms.find_by(id: params[:room_id])
        @message = room.messages.find_by(id: params[:message_id])
      end

      head :not_found unless @message
    end

    def set_boost
      super
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    def ensure_content_present
      if raw_boost_content.blank?
        head :unprocessable_content
      end
    end

    def boost_params
      { content: raw_boost_content }
    end

    def raw_boost_content
      @raw_boost_content ||= raw_request_body(
        maximum: ContentLimits::MESSAGE_BODY_BYTES, description: "boost content"
      )
    end
end
