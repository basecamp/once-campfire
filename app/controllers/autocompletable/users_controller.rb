class Autocompletable::UsersController < ApplicationController
  def index
    set_page_and_extract_portion_from find_autocompletable_users.with_attached_avatar.ordered, per_page: 20

    respond_to do |format|
      format.html { render layout: false } # <lexxy-prompt-item> elements for the mentions prompt
      format.json
    end
  end

  private
    def find_autocompletable_users
      if query.present?
        users_scope.active.filtered_by(query)
      else
        users_scope.active
      end
    end

    # The rich text editor's mentions prompt filters with `filter`, the
    # autocomplete inputs with `query`
    def query
      params[:filter].presence || params[:query].presence
    end

    def users_scope
      params[:room_id].present? ? Current.user.rooms.find(params[:room_id]).users : User.all
    end
end
