class Users::BansController < ApplicationController
  def update
    @user = User.find_by(id: params[:user_id])
    toggle_banned_flag if !@user.can_administer?

    redirect_to edit_account_url
  end

  private
  def toggle_banned_flag
    @user.banned? ? @user.unban : @user.ban
  end
end
