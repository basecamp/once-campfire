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
      permitted = params.require(:user).permit(:name, :avatar, :email_address, :password, :bio).compact
      if @user.sso?
        permitted.delete(:password) unless helpers.password_registration_enabled?
        permitted.delete(:name)
        permitted.delete(:email_address)
      end
      permitted
    end

    def update_notice
      params[:user][:avatar] ? "It may take up to 30 minutes to change everywhere." : "✓"
    end
end
