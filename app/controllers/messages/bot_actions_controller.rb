class Messages::BotActionsController < ApplicationController
  include RoomScoped

  rate_limit to: 30, within: 1.minute, by: -> { Current.user.id }, only: :create, with: -> { head :too_many_requests }

  def create
    message = @room.messages.find(params[:message_id])
    callback = message.with_lock do
      message.reload
      action = message.bot_action_with_value(params.require(:value))

      if action && !action["disabled"] && message.creator.bot? && message.creator.webhook
        { bot: message.creator, value: action["value"], selected: update_selection(message, action["value"]) }
      end
    end

    if callback
      Bot::ActionWebhookJob.perform_later(callback[:bot], message, Current.user, callback[:value], callback[:selected], event_id: SecureRandom.uuid)
      head :accepted
    else
      head :unprocessable_entity
    end
  end

  private
    def update_selection(message, value)
      return false if message.bot_action_selection_mode == "none"

      selection = message.bot_action_selections.create_or_find_by!(user: Current.user)
      selection.with_lock do
        current_values = normalized_values(selection.values, message)
        selection.update! values: toggled_values(current_values, value, mode: message.bot_action_selection_mode)
        selection.values.include?(value)
      end
    end

    def normalized_values(values, message)
      values = values & message.bot_actions.pluck("value")

      case message.bot_action_selection_mode
      when "none" then []
      when "single" then values.first(1)
      else values
      end
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
