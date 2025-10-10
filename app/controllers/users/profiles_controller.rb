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
      # Remove password and email_address from permitted params if local login is disabled
      permitted_params = [:name, :avatar, :bio]
      
      unless ENV['DISABLE_LOCAL_LOGIN'].to_s.downcase == 'true'
        permitted_params += [:email_address, :password]
      end
      
      params.require(:user).permit(*permitted_params).compact
    end

    def update_notice
      params[:user][:avatar] ? "It may take up to 30 minutes to change everywhere." : "✓"
    end
end
