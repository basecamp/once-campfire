class SessionsController < ApplicationController
  PASSWORD_ATTEMPT_LIMIT = 10
  PASSWORD_ATTEMPT_WINDOW = 3.minutes

  allow_unauthenticated_access only: %i[ new create ]

  before_action :ensure_user_exists, only: :new
  before_action :limit_password_attempts, only: :create

  def new
    Oidc.ensure_browser_binding! cookies if Oidc.enabled?
  end

  def create
    email_address = User.normalize_email_address(params[:email_address].to_s)
    user = User.active.authenticate_by(
      email_address:, normalized_email_address: email_address, password: params[:password]
    )

    if user && Oidc.local_authentication_allowed_for?(user)
      start_new_session_for user
      redirect_to post_authenticating_url
    else
      render_rejection :unauthorized
    end
  rescue Oidc::Activation::Error, ActiveRecord::ActiveRecordError
    render plain: "Authentication is temporarily unavailable.", status: :service_unavailable
  end

  def destroy
    remove_push_subscription
    terminate_current_session
    redirect_to root_url
  end

  private
    def ensure_user_exists
      redirect_to first_run_url if User.none?
    end

    def limit_password_attempts
      key = [ "password-login", request.remote_ip ].join(":")
      attempts = begin
        Rails.cache.increment(key, 1, expires_in: PASSWORD_ATTEMPT_WINDOW)
      rescue StandardError => error
        raise Oidc::PolicyUnavailable.new(Oidc::POLICY_UNAVAILABLE_MESSAGE), cause: error
      end
      unless attempts.is_a?(Integer)
        raise Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE
      end

      render_rejection :too_many_requests if attempts > PASSWORD_ATTEMPT_LIMIT
    end

    def render_rejection(status)
      params[:local] = "1" if Oidc.required? && Oidc.break_glass_user.present?
      flash.now[:alert] = "Too many requests or unauthorized."
      render :new, status: status
    end

    def remove_push_subscription
      if endpoint = params[:push_subscription_endpoint]
        Push::Subscription.destroy_by(endpoint: endpoint, user_id: Current.user.id)
      end
    end
end
