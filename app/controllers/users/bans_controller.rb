class Users::BansController < ApplicationController
  before_action :ensure_can_administer
  before_action :set_user

  def create
    @user.ban
    redirect_to @user
  end

  def destroy
    @user.unban
    redirect_to @user
  end

  private
    def set_user
      @user = User.find(params[:user_id])
    end
end
