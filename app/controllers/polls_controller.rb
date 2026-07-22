class PollsController < ApplicationController
  include PollParameters
  include RoomScoped

  def new
    @poll = Poll.new
    @client_message_id = pending_client_message_id
    Poll::MIN_OPTIONS.times.with_index { |_, i| @poll.options.build(position: i) }
  end

  def create
    @client_message_id = submitted_client_message_id || pending_client_message_id
    existing_message = @room.messages.find_by(client_message_id: @client_message_id)

    if existing_message
      clear_pending_client_message_id
      redirect_to room_path(@room)
    else
      message = @room.messages.create_with_attachment!(message_params.merge(creator: Current.user)) do |new_message|
        @poll = new_message.build_poll(poll_params)
      end

      message.broadcast_create
      clear_pending_client_message_id
      redirect_to room_path(@room)
    end
  rescue ActiveRecord::RecordInvalid => error
    @poll = error.record.is_a?(Poll) ? error.record : error.record.poll
    ensure_minimum_options

    render :new, status: :unprocessable_entity
  end

  private
    def message_params
      params.fetch(:message, ActionController::Parameters.new).permit(:client_message_id).reverse_merge(client_message_id: @client_message_id)
    end

    def pending_client_message_id
      session[pending_client_message_id_key] ||= Random.uuid
    end

    def submitted_client_message_id
      params.dig(:message, :client_message_id).presence
    end

    def clear_pending_client_message_id
      session.delete(pending_client_message_id_key)
    end

    def pending_client_message_id_key
      "room_#{@room.id}_poll_client_message_id"
    end

    def ensure_minimum_options
      start_position = @poll.options.size
      (Poll::MIN_OPTIONS - start_position).times do |i|
        @poll.options.build(position: start_position + i)
      end
    end
end
