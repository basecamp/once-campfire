class SsoSessionsController < ApplicationController
  allow_unauthenticated_access

  def create
    auth = request.env["omniauth.auth"]

    if auth.blank?
      redirect_to new_session_url, alert: "Authentication failed."
      return
    end

    user = SsoAuthentication.find_or_create_user_from(auth)

    if user.active?
      grant_membership_to_invited_room(user) if user.sessions.none?
      start_new_session_for(
        user,
        sso_provider: auth.provider.to_s,
        oidc_id_token: extract_oidc_id_token(auth)
      )
      redirect_to post_authenticating_url
    else
      redirect_to new_session_url, alert: "Your account has been deactivated."
    end
  rescue SsoAuthentication::Error => e
    Rails.logger.error "SSO authentication failed: #{e.message}"
    redirect_to new_session_url, alert: "Authentication failed."
  end

  def failure
    strategy = params[:strategy].to_s.presence&.upcase
    detail   = params[:detail].to_s.presence || params[:message].to_s.humanize
    detail   = detail.gsub(/\s+/, " ").strip.first(280)

    message = [ "SSO authentication failed", strategy&.then { "(#{_1})" }, detail.presence&.then { ": #{_1}" } ].compact.join(" ") + "."

    Rails.logger.error message
    redirect_to new_session_url, alert: message
  end

  private
    def grant_membership_to_invited_room(_user)
      # Room invite tokens are unused while Backlit owns membership sync.
    end

    def extract_oidc_id_token(auth)
      raw_token = auth.dig(:credentials, :id_token) ||
        auth.dig(:extra, :id_token) ||
        auth.dig(:extra, :raw_info, :id_token)

      raw_token.to_s.strip.presence
    end
end
