class Users::ProfilesController < ApplicationController
  before_action :set_user

  # Limited like signing in, so the current password can't be guessed here instead.
  rate_limit to: 10, within: 3.minutes, only: :update, if: :changing_password?,
    with: -> { redirect_to user_profile_url, alert: "Too many attempts. Try again in a few minutes." }

  def show
    @direct_memberships, @shared_memberships =
      Current.user.memberships.with_ordered_room.partition { |m| m.room.direct? }
  end

  def update
    if @user.update user_params
      start_new_session_for @user if @user.saved_change_to_password_digest?

      redirect_to user_profile_url, notice: update_notice
    else
      redirect_to user_profile_url, alert: update_alert
    end
  end

  private
    def set_user
      @user = Current.user
    end

    def user_params
      permitted = params.require(:user).permit(:name, :avatar, :email_address, :password, :bio).compact

      if changing_password?
        permitted.merge(password_challenge: params[:user][:password_challenge].to_s)
      else
        permitted
      end
    end

    # As has_secure_password reads it: an empty password leaves the current one alone.
    def changing_password?
      !params.dig(:user, :password).to_s.empty?
    end

    def update_notice
      params[:user][:avatar] ? "It may take up to 30 minutes to change everywhere." : "✓"
    end

    def update_alert
      if !@user.errors.include?(:password_challenge)
        @user.errors.full_messages.to_sentence
      elsif params[:user][:password_challenge].blank?
        "Enter your current password to change it."
      else
        "That isn't your current password."
      end
    end
end
