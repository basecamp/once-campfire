class SearchesController < ApplicationController
  before_action :set_messages

  def index
    @query = query if query.present?
    @recent_searches = Current.user.searches.ordered
    @return_to_room = last_room_visited
  end

  def create
    Search.record_for! Current.user, query
    redirect_to searches_url(q: query)
  end

  def clear
    Search.clear_for! Current.user
    redirect_to searches_url
  end

  private
    def set_messages
      if query.present?
        @messages = Current.user.reachable_messages.search(query).last(100)
      else
        @messages = Message.none
      end
    end

    def query
      params[:q]&.gsub(/[^[:word:]]/, " ")
    end
end
