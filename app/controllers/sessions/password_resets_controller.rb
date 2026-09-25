class Sessions::PasswordResetsController < ApplicationController
  allow_unauthenticated_access

  before_action :require_smpt

  def index
  end
  def new
  end

  def show
    @password_reset_id = params[:id]
    @user = User.find_by_password_reset_id(@password_reset_id)

    redirect_to root_url unless @user
  end

  def update
    @user = User.find_by_password_reset_id(password_reset_params[:password_reset_id])

    redirect_to root_url unless @user
    redirect_to root_url unless password_match?

    @user.update(password: password_reset_params[:new_password])

    redirect_to new_session_path
  end

  def create
    email = params[:email_address]
    password_reset_url = session_password_reset_url(find_user_by_email(email).password_reset_id)

    PasswordResetMailer.with(email: email, url: password_reset_url).password_reset_email.deliver_later

    redirect_to new_session_password_reset_path
  end

  private

  def require_smpt
    redirect_to root_url unless helpers.smtp_enabled?
  end

  def find_user_by_email(email)
    User.find_by(email_address: email)
  end

  def password_match?
    password_reset_params[:new_password] == password_reset_params[:confirm_new_password]
  end

  def password_reset_params
    params.require(:user).permit(:new_password, :confirm_new_password, :password_reset_id)
  end
end
