class UsersController < ApplicationController
  require_unauthenticated_access only: %i[ new create ]

  before_action :set_user, only: :show
  before_action :verify_join_code, only: %i[ new create ]
  before_action :check_local_registration_disabled, only: %i[ new create ]

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

    def verify_join_code
      head :not_found if Current.account.join_code != params[:join_code]
    end

    def check_local_registration_disabled
      if ENV['DISABLE_LOCAL_LOGIN'].to_s.downcase == 'true'
        redirect_to root_url, alert: "Local registration is disabled. Please contact your administrator."
      end
    end

    def user_params
      params.require(:user).permit(:name, :avatar, :email_address, :password)
    end
end
