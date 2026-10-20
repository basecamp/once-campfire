class Users::ProfilesController < ApplicationController
  before_action :set_user

  # Limited like signing in, so the current password can't be guessed here instead.
  rate_limit to: 10, within: 3.minutes, only: :update, if: :answering_password_challenge?,
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
  rescue ActiveRecord::RecordInvalid
    # The password changed again before this browser's new session could start, and that change signed it out.
    redirect_to new_session_url
  end

  private
    def set_user
      @user = Current.user
    end

    # Always with the challenge, so the model checks it whenever the save would change the password, however the
    # request spelled the new one.
    def user_params
      params.require(:user).permit(:name, :avatar, :email_address, :password, :bio).compact
        .merge(password_challenge: password_challenge)
    end

    # Only a string is a challenge, so the rate limit counts exactly what the model checks.
    def password_challenge
      challenge = params.dig(:user, :password_challenge)
      challenge.is_a?(String) ? challenge : ""
    end

    # Guessing the current password means sending one, so this is what the rate limit counts.
    def answering_password_challenge?
      !password_challenge.empty?
    end

    def update_notice
      params[:user][:avatar] ? "It may take up to 30 minutes to change everywhere." : "✓"
    end

    def update_alert
      if !@user.errors.include?(:password_challenge)
        @user.errors.full_messages.to_sentence
      elsif password_challenge.empty?
        "Enter your current password to change it."
      else
        "That isn't your current password."
      end
    end
end
