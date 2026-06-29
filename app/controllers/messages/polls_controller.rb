class Messages::PollsController < ApplicationController
  include PollParameters

  before_action :set_message
  before_action :ensure_can_administer

  def edit
    @poll = @message.poll
  end

  def update
    @poll = @message.poll
    return head :unprocessable_entity unless @poll.open?

    @poll.update!(editable_poll_params)
    broadcast_poll_update

    if request.format.turbo_stream?
      render turbo_stream: turbo_stream.replace(@message, partial: "messages/message", locals: { message: @message })
    elsif turbo_frame_request?
      render partial: "messages/message", locals: { message: @message }
    else
      redirect_to room_message_url(@message.room, @message)
    end
  end

  def close
    @message.poll.close!
    broadcast_poll_update

    head :ok
  end

  private
    def set_message
      @message = Message.find(params[:message_id])
    end

    def ensure_can_administer
      unless Current.user.can_administer?(@message)
        message = "Only the poll creator or an admin can edit or close this poll."

        if request.format.turbo_stream? || turbo_frame_request?
          render turbo_stream: turbo_stream.update("flash", partial: "layouts/flash", locals: { alert: true, message: message }), status: :forbidden
        else
          redirect_back fallback_location: room_path(@message.room), alert: message
        end
      end
    end

    def editable_poll_params
      @poll.structure_editable? ? poll_params : poll_params.slice(:question)
    end

    def broadcast_poll_update
      @message.broadcast_replace_to @message.room, :messages, target: @message, partial: "messages/message", locals: { message: @message }, attributes: { maintain_scroll: true }
    end
end
