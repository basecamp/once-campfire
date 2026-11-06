class Rooms::RefreshesController < ApplicationController
  include RoomScoped

  before_action :set_last_updated_at, :set_shown_message_ids

  def show
    @deleted_message_ids = @shown_message_ids - @room.messages.where(id: @shown_message_ids).ids
    @new_messages = @room.messages.with_presentation.page_created_since(@last_updated_at)
    @updated_messages = @room.messages.without(@new_messages).with_presentation.page_updated_since(@last_updated_at)
  end

  private
    def set_last_updated_at
      @last_updated_at = Time.at(0, params[:since].to_i, :millisecond)
    end

    def set_shown_message_ids
      @shown_message_ids = params[:shown].to_s.split(",").map(&:to_i)
    end
end
