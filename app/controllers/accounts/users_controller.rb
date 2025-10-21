class Accounts::UsersController < ApplicationController
  before_action :ensure_can_administer, :set_user, only: %i[ update destroy ]

  def index
    set_page_and_extract_portion_from User.active.ordered.without_bots, per_page: 500
  end

  def update
    @user.update(role_params)
    redirect_to edit_account_url
  end

  def destroy
    @user.deactivate
    redirect_to edit_account_url
  end

  private
    def set_user
      @user = User.active.find(params[:user_id] || params[:id])
    end

    def role_params
      {
        role: params.require(:user)[:role].presence_in(%w[ member administrator ]) || "member",
        banned: params.require(:user)[:banned] == "1"
      }
    end
end
