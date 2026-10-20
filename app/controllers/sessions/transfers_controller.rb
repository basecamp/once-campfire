class Sessions::TransfersController < ApplicationController
  allow_unauthenticated_access

  def show
  end

  def update
    if user = User.active.find_by_transfer_id(params[:id])
      start_new_session_for user
      redirect_to post_authenticating_url
    else
      head :bad_request
    end
  rescue ActiveRecord::RecordInvalid
    head :bad_request
  end
end
