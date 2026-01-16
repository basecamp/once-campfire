class AccountsController < ApplicationController
  before_action :ensure_can_administer, only: :update
  before_action :set_account

  def edit
    users = account_users.ordered.without_bots
    @administrators, @members = users.partition(&:administrator?)
    set_page_and_extract_portion_from users, per_page: 500
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
      params.require(:account).permit(:name, :logo, settings: {})
    end

    def account_users
      if Current.user.can_administer?
        User.where(status: [ :active, :banned ])
      else
        User.active
      end
    end
end
