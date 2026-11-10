class Rooms::ArchivedController < ApplicationController
  before_action :ensure_administrator
  before_action :set_room, only: :show

  def index
    @rooms = Room.archived.ordered
  end

  def show
    @messages = @room.messages.with_presentation.last_page
    render template: "rooms/show"
  end

  private
    def ensure_administrator
      head :forbidden unless Current.user.administrator?
    end

    def set_room
      @room = Room.archived.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to rooms_archived_index_url, alert: "That archived room is gone."
    end
end
