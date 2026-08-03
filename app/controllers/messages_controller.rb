class MessagesController < ApplicationController
  include ActiveStorage::SetCurrent, RoomScoped

  before_action :set_room, except: :create
  before_action :set_message, only: %i[ show edit update destroy ]
  before_action :ensure_can_administer, only: :edit

  layout false, only: :index

  def index
    @messages = find_paged_messages

    if @messages.any?
      fresh_when @messages
    else
      head :no_content
    end
  end

  def create
    set_room
    @message = @room.messages.create_with_attachment!(message_params)
  rescue Message::ClientMessageIdConflict
    head :conflict
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ActiveRecord::RecordInvalid
    head :unprocessable_entity
  end

  def show
  end

  def edit
  end

  def update
    @message.update_with_broadcast!(message_update_params, actor: Current.user)
    redirect_to room_message_url(@room, @message)
  end

  def destroy
    @message.destroy_with_broadcast! actor: Current.user
  end

  private
    def set_message
      @message = @room.messages.find(params[:id])
    end

    def ensure_can_administer
      head :forbidden unless Current.user.can_administer?(@message)
    end


    def find_paged_messages
      case
      when params[:before].present?
        @room.messages.with_creator.page_before(@room.messages.find(params[:before]))
      when params[:after].present?
        @room.messages.with_creator.page_after(@room.messages.find(params[:after]))
      else
        @room.messages.with_creator.last_page
      end
    end


    def message_params
      params.require(:message).permit(:body, :attachment, :client_message_id)
    end

    def message_update_params
      attributes = params.require(:message)
      if attributes.key?(:attachment) || attributes.key?(:client_message_id)
        raise ActionController::BadRequest, "message attachments and client IDs cannot be updated"
      end

      attributes.permit(:body)
    end
end
