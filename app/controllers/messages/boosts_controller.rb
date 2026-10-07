class Messages::BoostsController < ApplicationController
  before_action :set_message
  before_action :set_boost, only: :destroy

  def index
  end

  def new
  end

  def create
    @boost = @message.boosts.create!(boost_params)

    broadcast_create
    redirect_to message_boosts_url(@message)
  end

  def destroy
    @boost.destroy!

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
        target: helpers.dom_id(@boost.message, :boosts), partial: "messages/boosts/boost", attributes: { maintain_scroll: true }
    end

    def broadcast_remove
      @boost.broadcast_remove_to @boost.message.room, :messages
    end
end
