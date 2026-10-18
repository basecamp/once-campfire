class Rooms::RefreshesController < ApplicationController
  include RoomScoped

  before_action :set_last_updated_at

  def show
    # Appending only the first page of what was posted meanwhile would leave the rest out for good: the page counts
    # itself up to date, and the next live message lands right after that first page. So when more was posted than a
    # page holds, the latest page takes the place of the messages shown, as reloading the room would.
    if @room.messages.created_since(@last_updated_at).paged?
      @last_page = @room.messages.with_presentation.last_page
      # A reader of older messages keeps them in place of the latest page, and still gets what changed on them.
      @updated_messages = @room.messages.where(created_at: ..@last_updated_at).with_presentation.page_updated_since(@last_updated_at)
    else
      @new_messages = @room.messages.with_presentation.page_created_since(@last_updated_at)
      @updated_messages = @room.messages.without(@new_messages).with_presentation.page_updated_since(@last_updated_at)
    end
  end

  private
    def set_last_updated_at
      @last_updated_at = Time.at(0, params[:since].to_i, :millisecond)
    end
end
