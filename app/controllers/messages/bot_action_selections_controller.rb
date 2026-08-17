class Messages::BotActionSelectionsController < ApplicationController
  include RoomScoped

  def index
    message_ids = Array(params[:message_ids]).first(100)
    messages = @room.messages.where(id: message_ids).includes(:bot_action_selections)

    render json: messages.to_h { |message| [ message.id, selected_values(message) ] }
  end

  private
    def selected_values(message)
      values = message.bot_action_selections.find { |selection| selection.user_id == Current.user.id }&.values || []
      values &= message.bot_actions.pluck("value")

      case message.bot_action_selection_mode
      when "none" then []
      when "single" then values.first(1)
      else values
      end
    end
end
