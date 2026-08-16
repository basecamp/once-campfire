class Messages::BotActionsController < ApplicationController
  include RoomScoped

  rate_limit to: 30, within: 1.minute, only: :create, with: -> { head :too_many_requests }

  def selection
    message = @room.messages.find(params[:message_id])
    render json: { values: message.bot_action_selections.find_by(user: Current.user)&.values || [] }
  end

  def create
    message = @room.messages.find(params[:message_id])
    action = message.bot_action_with_value(params.require(:value))

    if action && !action["disabled"] && message.creator.bot? && message.creator.webhook
      selected = update_selection(message, action["value"])
      Bot::ActionWebhookJob.perform_later(message.creator, message, Current.user, action["value"], selected)
      head :accepted
    else
      head :unprocessable_entity
    end
  end

  private
    def update_selection(message, value)
      return false if message.bot_action_selection_mode == "none"

      selection = message.bot_action_selections.find_or_initialize_by(user: Current.user)
      current_values = selection.values & message.bot_actions.pluck("value")
      selection.values = toggled_values(current_values, value, mode: message.bot_action_selection_mode)
      selection.save!
      selection.values.include?(value)
    end

    def toggled_values(values, value, mode:)
      if values.include?(value)
        values.excluding(value)
      elsif mode == "multiple"
        values.including(value)
      else
        [ value ]
      end
    end
end
