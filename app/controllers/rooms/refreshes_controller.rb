class Rooms::RefreshesController < ApplicationController
  include RoomScoped

  before_action :set_last_updated_at

  def show
    @new_messages = @room.messages.with_presentation.page_created_since(@last_updated_at)
    @updated_messages = @room.messages.without(@new_messages).with_presentation.page_updated_since(@last_updated_at)
    # More was posted than one page holds. The page is told so, and loads the rest as it does when scrolling down,
    # instead of counting itself up to date after the first page.
    @more_messages = @room.messages.created_since(@last_updated_at).paged?
  end

  private
    def set_last_updated_at
      @last_updated_at = Time.at(0, params[:since].to_i, :millisecond)
    end
end
