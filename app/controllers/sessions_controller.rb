class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create oidc ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { render_rejection :too_many_requests }

  before_action :ensure_user_exists, only: :new
  before_action :check_local_login_disabled, only: :create

  def new
  end

  def create
    if params[:oidc_login]
      if ENV['DISABLE_SSO'].to_s.downcase == 'true'
        flash[:alert] = "SSO login is disabled."
        redirect_to new_session_url
      else
        redirect_to oidc_session_path, allow_other_host: true
      end
    elsif user = User.active.authenticate_by(email_address: params[:email_address], password: params[:password])
      start_new_session_for user
      redirect_to post_authenticating_url
    else
      render_rejection :unauthorized
    end
  end

  def oidc
    if ENV['DISABLE_SSO'].to_s.downcase == 'true'
      flash[:alert] = "SSO login is disabled."
      redirect_to new_session_url
    else
      redirect_to '/auth/oidc', allow_other_host: true
    end
  end

  def destroy
    remove_push_subscription
    reset_authentication
    redirect_to root_url
  end

  private
    def ensure_user_exists
      redirect_to first_run_url if User.none?
    end

    def check_local_login_disabled
      if ENV['DISABLE_LOCAL_LOGIN'].to_s.downcase == 'true' && !params[:oidc_login]
        flash[:alert] = "Local login is disabled. Please use SSO to sign in."
        redirect_to new_session_url
      end
    end

    def render_rejection(status)
      flash.now[:alert] = "Too many requests or unauthorized."
      render :new, status: status
    end

    def remove_push_subscription
      if endpoint = params[:push_subscription_endpoint]
        Push::Subscription.destroy_by(endpoint: endpoint, user_id: Current.user.id)
      end
    end
end
