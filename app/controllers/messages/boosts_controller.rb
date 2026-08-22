class Messages::BoostsController < ApplicationController
  before_action :set_message
  before_action :set_boost, only: :destroy

  def index
  end

  def new
  end

  def create
    @boost = Boost.create_by!(
      message: @message, actor: Current.user, attributes: boost_params, authenticated_bot_key:
    )

    broadcast_create
    redirect_to message_boosts_url(@message)
  end

  def destroy
    @boost = Boost.destroy_by!(id: @boost.id, actor: Current.user, authenticated_bot_key:)

    broadcast_remove
  end

  private
    def set_message
      @message = Current.user.reachable_messages.find(params[:message_id])
    end

    def set_boost
      @boost = @message.boosts.find_by!(id: params[:id], booster: Current.user)
    end

    def boost_params
      params.require(:boost).permit(:content)
    end

    def broadcast_create
      @boost.broadcast_append_to @boost.message.room, :messages,
        target: ActionView::RecordIdentifier.dom_id(@boost.message, :boosts),
        partial: "messages/boosts/boost", attributes: { maintain_scroll: true }
    end

    def broadcast_remove
      @boost.broadcast_remove_to @boost.message.room, :messages
    end
end
