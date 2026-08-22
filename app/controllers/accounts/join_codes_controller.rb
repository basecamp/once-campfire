class Accounts::JoinCodesController < ApplicationController
  before_action :ensure_can_administer

  def create
    Current.account.reset_join_code! actor: Current.user
    redirect_to edit_account_url
  end
end
