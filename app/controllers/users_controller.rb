class UsersController < ApplicationController
  require_unauthenticated_access only: %i[ new create ]

  before_action :set_user, only: :show
  before_action :ensure_password_registration_enabled, only: %i[ new create ]
  before_action :verify_join_code, only: %i[ new create ]

  def new
    @user = User.new
  end

  def create
    @user = User.create!(user_params)
    start_new_session_for @user
    redirect_to root_url
  rescue ActiveRecord::RecordNotUnique
    redirect_to new_session_url(email_address: user_params[:email_address])
  end

  def show
  end

  private
    def set_user
      @user = User.find(params[:id])
    end

    def ensure_password_registration_enabled
      unless helpers.password_registration_enabled?
        redirect_to new_session_url, alert: "Sign in with your SSO provider to join."
      end
    end

    def verify_join_code
      head :not_found if Current.account.join_code != params[:join_code]
    end

    def user_params
      params.require(:user).permit(:name, :avatar, :email_address, :password)
    end
end
