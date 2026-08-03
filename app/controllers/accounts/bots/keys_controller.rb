class Accounts::Bots::KeysController < ApplicationController
  before_action :ensure_can_administer

  def update
    User.active_bots.find(params[:bot_id]).reset_bot_key! actor: Current.user
    redirect_to account_bots_url
  end
end
