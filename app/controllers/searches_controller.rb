class SearchesController < ApplicationController
  before_action :set_messages

  def index
    @query = query if query.present?
    @recent_searches = Current.user.searches.ordered
    @return_to_room = last_room_visited
  end

  def create
    Current.user.searches.record(query)
    redirect_to searches_url(q: query)
  end

  def clear
    Current.user.searches.destroy_all
    redirect_to searches_url
  end

  private
    def set_messages
      if query.present?
        @messages = Current.user.reachable_messages.search(query).with_presentation.last_page_of_matches(100)
      else
        @messages = Message.none
      end
    end

    def query
      params[:q]&.gsub(/[^[:word:]]/, " ")
    end
end
