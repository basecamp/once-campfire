class Oidc::SessionsController < ApplicationController
  allow_unauthenticated_access

  def new
    head :not_found
  end

  def create
    flow = request.env["oidc.flow"]
    auth = request.env["omniauth.auth"]
    @linking_attempt = flow&.operation == "link" || session[Oidc::LINKING_INTENT_SESSION_KEY].present?
    @authentication_failure_url = @linking_attempt ? user_profile_url : new_session_url
    linking_session_id, linking_return_to, linking_authorization = consume_linking_intent(flow)
    return_to = linking_return_to || post_authenticating_url

    provider_session_attributes = Identity.provider_session_attributes(auth)
    new_session = Identity.with_authentication_fence(auth) do |identity_authentication|
      Oidc::SessionGeneration.current!
      authenticate = proc do
        account = Account.lock.sole
        if account.oidc_transition_state == "rollback_prepared"
          raise Identity::AuthenticationError, "rollback_prepared"
        end

        existing_session = find_session_by_cookie(lock: true)
        if flow && existing_session&.id != flow.initiating_session_id
          raise Identity::AuthenticationError, "initiating_session_changed"
        end
        linking_session = if linking_session_id
          unless existing_session&.id == linking_session_id
            raise Identity::AuthenticationError, "invalid_linking_intent"
          end
          existing_session
        end
        identity = identity_authentication.complete!(
          linking_user: linking_session&.user,
          linking_authorization: (linking_authorization if linking_session)
        )
        if existing_session && !linking_session && existing_session.user_id != identity.user_id
          raise Identity::AuthenticationError, "account_switch_requires_logout"
        end

        new_session = identity.user.sessions.start!(
          user_agent: request.user_agent,
          ip_address: request.remote_ip,
          identity:,
          **provider_session_attributes
        )
        Oidc::Activation.record_successful_authentication!(account:)
        (linking_session || existing_session)&.push_subscriptions&.update_all(session_id: new_session.id)
        (linking_session || existing_session)&.destroy!
        new_session
      end
      flow ? flow.finalize!(&authenticate) : Account.transaction(&authenticate)
    end

    reset_session
    authenticated_as new_session
    if Oidc.required? && !Oidc::Activation.ready?
      flash[:oidc_verified] = true
      redirect_to new_session_url
    else
      redirect_to return_to
    end
  rescue Identity::AuthenticationError, Oidc::Flow::Invalid, ActiveRecord::ActiveRecordError => error
    fail_authentication error
  end

  def failure
    @linking_attempt = session[Oidc::LINKING_INTENT_SESSION_KEY].present?
    @authentication_failure_url = @linking_attempt ? user_profile_url : new_session_url
    fail_authentication request.env["omniauth.error"]
  end

  private
    def consume_linking_intent(flow = nil)
      intent = session.delete(Oidc::LINKING_INTENT_SESSION_KEY)
      if flow
        return [ nil, nil, nil ] unless flow.operation == "link"
        return [ flow.linking_session_id, flow.return_to, validated_linking_authorization!(intent) ]
      end
      return [ nil, nil, nil ] unless intent

      unless intent.is_a?(Hash) && intent["expires_at"].to_i > Time.current.to_i &&
          intent["state"].present? && ActiveSupport::SecurityUtils.secure_compare(intent["state"], params[:state].to_s)
        raise Identity::AuthenticationError, "invalid_linking_intent"
      end

      [ intent["session_id"], intent["return_to"], validated_linking_authorization!(intent) ]
    end

    def validated_linking_authorization!(intent)
      authorization = intent&.fetch("authorization", nil)
      valid = authorization.is_a?(Hash) &&
        (authorization["method"] == "password" ||
          (authorization["method"] == "identity" && authorization["subject"].is_a?(String)))
      raise Identity::AuthenticationError, "invalid_linking_intent" unless valid

      authorization
    end

    def fail_authentication(error)
      reason = if error.is_a?(Identity::AuthenticationError)
        error.message
      elsif error.respond_to?(:error)
        error.error.to_s
      else
        "unexpected_error"
      end
      reason = "unexpected_error" unless reason.match?(/\A[a-z0-9_]+\z/)
      Rails.logger.warn "OIDC authentication failed request_id=#{request.request_id} reason=#{reason} error=#{error&.class&.name || 'unknown'}"
      reset_session
      redirect_to @authentication_failure_url || new_session_url,
        alert: "Single sign-on could not be completed. Please try again or contact an administrator."
    end
end
