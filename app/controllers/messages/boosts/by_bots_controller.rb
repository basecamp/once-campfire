class Messages::Boosts::ByBotsController < Messages::BoostsController
  include RawRequestBody

  allow_bot_access only: %i[ create destroy ]

  before_action :ensure_content_present, only: :create

  def create
    @boost = @message.boosts.create!(boost_params)

    broadcast_create
    render :show, status: :created
  end

  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { errors: error.record.errors.to_hash }, status: :unprocessable_content
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
      if raw_request_body.blank?
        head :unprocessable_content
      end
    end

    def boost_params
      { content: raw_request_body }
    end
end
