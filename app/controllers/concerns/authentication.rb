module Authentication
  extend ActiveSupport::Concern
  include SessionLookup

  PASSWORD_REAUTHENTICATION_ATTEMPT_LIMIT = 5
  PASSWORD_REAUTHENTICATION_ATTEMPT_WINDOW = 10.minutes
  PASSWORD_REAUTHENTICATION_LIFETIME = 5.minutes
  PASSWORD_REAUTHENTICATION_SESSION_KEY = "password_reauthentication"

  included do
    before_action :require_authentication
    before_action :deny_bots
    helper_method :signed_in?

    protect_from_forgery with: :exception, unless: -> { authenticated_by.bot_key? }
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end

    def allow_bot_access(**options)
      skip_before_action :deny_bots, **options
    end

    def require_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
      before_action :restore_authentication, :redirect_signed_in_user_to_root, **options
    end
  end

  private
    # An earlier cookie copy cannot inherit proof added to this encrypted browser session later.
    def record_password_reauthentication!(user = Current.user)
      session[PASSWORD_REAUTHENTICATION_SESSION_KEY] = {
        "session_id" => Current.session.id,
        "verified_at" => Time.current.to_i,
        "password_digest" => password_reauthentication_fingerprint(user)
      }
    end

    def clear_password_reauthentication!
      session.delete PASSWORD_REAUTHENTICATION_SESSION_KEY
    end

    def password_reauthentication_expires_at(user = Current.user)
      proof = session[PASSWORD_REAUTHENTICATION_SESSION_KEY]
      unless proof.is_a?(Hash)
        clear_password_reauthentication!
        return
      end

      now = Time.current.to_i
      verified_at = proof.fetch("verified_at", 0).to_i
      valid = Current.session &&
        proof.fetch("session_id", 0).to_i == Current.session.id &&
        verified_at.between?(now - PASSWORD_REAUTHENTICATION_LIFETIME.to_i + 1, now) &&
        ActiveSupport::SecurityUtils.secure_compare(
          proof.fetch("password_digest", "").to_s,
          password_reauthentication_fingerprint(user)
        )
      return verified_at + PASSWORD_REAUTHENTICATION_LIFETIME.to_i if valid

      clear_password_reauthentication!
      nil
    end

    def password_reauthentication_rate_limited?(user = Current.user)
      key = [ "password-reauthentication", user.id ].join(":")
      attempts = begin
        Rails.cache.increment(
          key, 1, expires_in: PASSWORD_REAUTHENTICATION_ATTEMPT_WINDOW
        )
      rescue StandardError => error
        raise Oidc::PolicyUnavailable.new(Oidc::POLICY_UNAVAILABLE_MESSAGE), cause: error
      end
      unless attempts.is_a?(Integer)
        raise Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE
      end
      attempts > PASSWORD_REAUTHENTICATION_ATTEMPT_LIMIT
    end

    def password_reauthentication_fingerprint(user)
      Digest::SHA256.hexdigest user.password_digest.to_s
    end

    def signed_in?
      Current.user.present?
    end

    def require_authentication
      restore_authentication || bot_authentication || request_authentication
    end

    def restore_authentication
      if session = find_session_by_cookie
        resume_session session
      end
    end

    def bot_authentication
      bot_key, = ActionController::HttpAuthentication::Token.token_and_options(request)
      if bot_key.present? && bot = User.authenticate_bot(bot_key.strip)
        Current.user = bot
        set_authenticated_by(:bot_key)
      end
    end

    def request_authentication
      if request.get? || request.head?
        session[:return_to_after_authenticating] = canonical_request_url
        redirect_to new_session_url
      else
        head :unauthorized
      end
    end

    def redirect_signed_in_user_to_root
      redirect_to root_url if signed_in?
    end

    def start_new_session_for(user, identity: nil, authentication_method: nil)
      previous_session = find_session_by_cookie
      new_session = Account.transaction do
        account = Account.lock.sole
        if account.oidc_transition_state == "rollback_prepared"
          raise Oidc::Activation::Error, "rollback preparation is active"
        end

        user.sessions.start!(user_agent: request.user_agent, ip_address: request.remote_ip, identity:, authentication_method:).tap do
          previous_session&.destroy!
        end
      end
      authenticated_as new_session
    end

    def resume_session(session)
      session.resume user_agent: request.user_agent, ip_address: request.remote_ip
      authenticated_as session
    end

    def terminate_current_session
      Current.session&.destroy!
      reset_session
      remove_authentication_cookie
    end

    def authenticated_as(session)
      Current.session = session
      set_authenticated_by(:session)
      set_authentication_cookie(session)
    end

    def post_authenticating_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def set_authentication_cookie(session)
      cookies.signed.permanent[:session_token] = {
        value: session.token, httponly: true, same_site: :lax, secure: Oidc.enabled?
      }
    end

    def remove_authentication_cookie
      cookies.delete(:session_token)
    end

    def deny_bots
      head :forbidden if authenticated_by.bot_key?
    end

    def set_authenticated_by(method)
      @authenticated_by = method.to_s.inquiry
    end

    def authenticated_by
      @authenticated_by ||= "".inquiry
    end
end
