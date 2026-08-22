class Oidc::LinksController < ApplicationController
  before_action :require_enabled_oidc
  before_action :limit_password_verification_attempts, only: :update, if: :first_identity_link?

  def show
    Oidc.ensure_browser_binding! cookies
    return redirect_to oidc_flow_url if Oidc::Flow.pending_for?(cookies[Oidc::BROWSER_COOKIE])

    if current_identity
      authorization = { "method" => "identity", "subject" => current_identity.subject }
      expires_at = 5.minutes.from_now.to_i
    elsif proof_expires_at = password_reauthentication_expires_at
      authorization = { "method" => "password" }
      expires_at = [ 5.minutes.from_now.to_i, proof_expires_at ].min
    else
      session.delete Oidc::LINKING_INTENT_SESSION_KEY
      @password_reauthentication_required = true
      return
    end

    @linking_state = SecureRandom.hex(32)
    session[Oidc::LINKING_INTENT_SESSION_KEY] = {
      "session_id" => Current.session.id,
      "expires_at" => expires_at,
      "state" => @linking_state,
      "return_to" => user_profile_url,
      "authorization" => authorization
    }
  end

  def update
    session.delete Oidc::LINKING_INTENT_SESSION_KEY
    if current_identity
      redirect_to oidc_link_path
    elsif Current.user.authenticate_password(params[:current_password].to_s)
      record_password_reauthentication!
      redirect_to oidc_link_path
    else
      clear_password_reauthentication!
      redirect_to oidc_link_path, alert: "Current password is incorrect."
    end
  end

  private
    def current_identity
      @current_identity ||= Current.user.identities.find_by(issuer: Oidc.issuer)
    end

    def first_identity_link?
      current_identity.nil?
    end

    def limit_password_verification_attempts
      return unless password_reauthentication_rate_limited?

      session.delete Oidc::LINKING_INTENT_SESSION_KEY
      @password_reauthentication_required = true
      flash.now[:alert] = "Too many password attempts. Try again later."
      render :show, status: :too_many_requests
    end

    def require_enabled_oidc
      head :not_found unless Oidc.enabled?
    end
end
