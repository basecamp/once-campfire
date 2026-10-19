class Users::ProfilesController < ApplicationController
  before_action :set_user

  def show
    @direct_memberships, @shared_memberships =
      Current.user.memberships.with_ordered_room.partition { |m| m.room.direct? }
  end

  def update
    @user.update user_params
    redirect_to user_profile_url, notice: update_notice
  end

  private
    def set_user
      @user = Current.user
    end

    def user_params
      params.require(:user).permit(:name, :avatar, :email_address, :password, :bio).compact
    end

    def update_notice
      params[:user][:avatar] ? "It may take up to 30 minutes to change everywhere." : "✓"
    end
end
