class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { render_rejection :too_many_requests }

  before_action :ensure_user_exists, only: :new

  def new
  end

  def create
    if user = User.active.authenticate_by(email_address: params[:email_address], password: params[:password])
      start_new_session_for user
      redirect_to post_authenticating_url
    elsif helpers.sso_enabled? && User.active.find_by(email_address: params[:email_address])&.sso?
      flash.now[:alert] = "This account uses Single Sign-On."
      render :new, status: :unauthorized
    else
      render_rejection :unauthorized
    end
  end

  def destroy
    oidc_logout_url = OidcLogout.logout_url_for(
      strategy: Current.session&.sso_provider,
      id_token_hint: Current.session&.oidc_id_token,
      post_logout_redirect_uri: root_url
    )

    remove_push_subscription
    terminate_current_session
    redirect_to oidc_logout_url || root_url, allow_other_host: oidc_logout_url.present?
  end

  private
    def ensure_user_exists
      redirect_to first_run_url if User.none?
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
