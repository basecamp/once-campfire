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

    message = [ "SSO authentication failed", strategy&.then { "(#{_1})" }, detail.presence&.then { "— #{_1}" } ].compact.join(" ") + "."

    Rails.logger.error message
    redirect_to new_session_url, alert: message
  end

  private
    def grant_membership_to_invited_room(user)
      room = invited_room_from_return_url
      return unless room

      Membership.create_or_find_by!(room:, user:) do |membership|
        membership.involvement = room.default_involvement
      end
    end

    def invited_room_from_return_url
      return_to = session[:return_to_after_authenticating].to_s
      return if return_to.blank?

      uri = URI.parse(return_to)
      room_id = uri.path[%r{\A/rooms/(?<id>\d+)(?:/|$)}, :id]&.to_i
      invite_token = Rack::Utils.parse_nested_query(uri.query.to_s)["invite"].to_s.presence

      return if room_id.blank? || invite_token.blank?

      room = Room.find_by_sso_invite_token(invite_token)
      room if room&.id == room_id
    rescue URI::InvalidURIError
      nil
    end

    def extract_oidc_id_token(auth)
      raw_token = auth.dig(:credentials, :id_token) ||
        auth.dig(:extra, :id_token) ||
        auth.dig(:extra, :raw_info, :id_token)

      raw_token.to_s.strip.presence
    end
end
