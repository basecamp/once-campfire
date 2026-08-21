class AccountsController < ApplicationController
  before_action :ensure_can_administer, only: :update
  before_action :set_account
  skip_around_action :with_session_mutation_fence, only: :update

  def edit
    users = account_users.ordered.without_bots
    @administrators, @members = users.partition(&:administrator?)
    set_page_and_extract_portion_from users, per_page: 500
  end

  def update
    @account.update_with_staged_logo! account_params, actor: Current.user, current_session: Current.session
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
