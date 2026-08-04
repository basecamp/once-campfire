class Users::ProfilesController < ApplicationController
  PASSWORD_ATTEMPT_LIMIT = Authentication::PASSWORD_REAUTHENTICATION_ATTEMPT_LIMIT
  PASSWORD_ATTEMPT_WINDOW = Authentication::PASSWORD_REAUTHENTICATION_ATTEMPT_WINDOW

  before_action :set_user
  before_action :limit_password_verification_attempts, only: :update, if: :password_reauthentication_requested?

  def show
    @direct_memberships, @shared_memberships =
      Current.user.memberships.with_ordered_room.partition { |m| m.room.direct? }
  end

  def update
    if forbidden_recovery_email_change?
      redirect_to user_profile_path, alert: "The recovery email cannot be changed while required single sign-on is active."
    else
      password_reauthenticated = password_reauthentication_requested?
      password_changed = password_change_requested?
      @user.update_with_staged_avatar! user_params,
        actor: Current.user, current_password: params.dig(:user, :current_password), current_session: Current.session
      if password_changed
        Current.session.reload
        set_authentication_cookie Current.session
        Current.session.disconnect_remote_connections
      end
      record_password_reauthentication! @user if password_reauthenticated
      redirect_to user_profile_path, notice: update_notice
    end
  rescue User::Avatar::PasswordVerificationFailed
    redirect_to user_profile_path, alert: "Current password is incorrect."
  rescue ActiveRecord::RecordNotUnique
    redirect_to user_profile_path, alert: "Email address is already in use."
  end

  private
    def set_user
      @user = Current.user
    end

    def user_params
      permitted = %i[ name avatar email_address bio ]
      permitted << :password if Oidc.local_authentication_allowed_for?(@user)
      permitted.delete(:email_address) if Oidc.required_active? && Oidc.break_glass?(@user)
      params.require(:user).permit(*permitted).compact
    end

    def password_change_requested?
      Oidc.local_authentication_allowed_for?(@user) && params.dig(:user, :password).present?
    end

    def password_reauthentication_requested?
      password_change_requested? || password_account_email_change_requested?
    end

    def password_account_email_change_requested?
      attributes = params[:user]
      attributes&.key?(:email_address) &&
        User.normalize_email_address(attributes[:email_address]) != @user.email_address &&
        !@user.identities.exists?(issuer: Oidc.issuer)
    end

    def forbidden_recovery_email_change?
      Oidc.required_active? && Oidc.break_glass?(@user) &&
        params.dig(:user, :email_address).present? &&
        User.normalize_email_address(params.dig(:user, :email_address)) != @user.email_address
    end

    def limit_password_verification_attempts
      return unless password_reauthentication_rate_limited?(@user)

      @direct_memberships, @shared_memberships = Current.user.memberships.with_ordered_room.partition { |membership| membership.room.direct? }
      flash.now[:alert] = "Too many password attempts. Try again later."
      render :show, status: :too_many_requests
    end

    def update_notice
      params[:user][:avatar] ? "It may take up to 30 minutes to change everywhere." : "✓"
    end
end
