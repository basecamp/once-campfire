class Messages::Boosts::ByBotsController < ApplicationController
  allow_bot_access only: :create

  def create
    set_message
    @boost = @message.boosts.create!(content: read_body)

    broadcast_create
    head :created
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private
    def set_message
      @room = Current.user.rooms.find(params[:room_id])
      @message = @room.messages.find(params[:message_id])
    end

    def read_body
      request.body.rewind
      request.body.read.force_encoding("UTF-8")
    ensure
      request.body.rewind
    end

    def broadcast_create
      @boost.broadcast_append_to @boost.message.room, :messages,
        target: "boosts_message_#{@boost.message.client_message_id}",
        partial: "messages/boosts/boost",
        attributes: { maintain_scroll: true }
    end
end
