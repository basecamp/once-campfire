class Messages::BotActionSelectionsController < ApplicationController
  include RoomScoped

  MAX_MESSAGES = 100

  def index
    messages = @room.messages.where(id: message_ids)

    render json: messages.to_h { |message| [ message.id, selected_values(message) ] }
  end

  private
    def message_ids
      @message_ids ||= begin
        ids = params[:message_ids]
        ids = ids.respond_to?(:to_ary) ? ids.to_ary : Array(ids)

        if ids.size > MAX_MESSAGES
          raise ActionController::BadRequest, "Requested #{ids.size} messages, at most #{MAX_MESSAGES} are allowed"
        end

        ids.grep_v(ActionController::Parameters)
      end
    end

    # Only the current user's selections are ever exposed, so preload just those
    # rather than every member's rows for every requested message.
    def selections_by_message_id
      @selections_by_message_id ||= BotActionSelection.where(message_id: message_ids, user: Current.user).index_by(&:message_id)
    end

    def selected_values(message)
      values = selections_by_message_id[message.id]&.values || []
      values &= message.bot_actions.pluck("value")

      case message.bot_action_selection_mode
      when "none" then []
      when "single" then values.first(1)
      else values
      end
    end
end
