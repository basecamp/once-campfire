class AccountsController < ApplicationController
  before_action :ensure_can_administer, only: :update
  before_action :set_account

  def edit
    set_page_and_extract_portion_from User.active_and_banned.order(:banned).ordered, per_page: 500
  end

  def update
    @account.update!(account_params)
    redirect_to edit_account_url, notice: "✓"
  end

  private
    def set_account
      @account = Current.account
    end

    def account_params
      params.require(:account).permit(:name, :logo)
    end
end
