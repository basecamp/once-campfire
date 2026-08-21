class Sessions::TransfersController < ApplicationController
  class AccountSwitchForbidden < StandardError; end

  TRANSFER_INTENT_SESSION_KEY = "credential_intent.transfer"

  allow_unauthenticated_access

  def show
    return redirect_to new_session_path, alert: "Session transfer is unavailable while single sign-on is enabled." if Oidc.enabled?

    @transfer_ready = CredentialIntent.valid_transfer?(session[TRANSFER_INTENT_SESSION_KEY])
    session.delete TRANSFER_INTENT_SESSION_KEY unless @transfer_ready
  end

  def intent
    return head :forbidden if Oidc.enabled?

    session[TRANSFER_INTENT_SESSION_KEY] = CredentialIntent.exchange_transfer!(params[:token])
    redirect_to session_transfer_path
  rescue CredentialIntent::Invalid
    session.delete TRANSFER_INTENT_SESSION_KEY
    redirect_to session_transfer_path, alert: "That session transfer link is invalid or has already been used."
  end

  def update
    return head :forbidden if Oidc.enabled?

    token = session[TRANSFER_INTENT_SESSION_KEY]
    new_session = CredentialIntent.consume_transfer!(token) do |user|
      current_session = find_session_by_cookie
      if current_session && current_session.user_id != user.id
        raise AccountSwitchForbidden, "an authenticated user cannot be replaced by a transfer"
      end

      create_new_session_for user, authentication_method: "transfer"
    end
    session.delete TRANSFER_INTENT_SESSION_KEY
    authenticated_as new_session
    redirect_to post_authenticating_url
  rescue AccountSwitchForbidden
    redirect_to root_path, alert: "Sign out before transferring a different account to this browser."
  rescue CredentialIntent::Invalid
    head :bad_request
  rescue Oidc::Activation::Error, ActiveRecord::ActiveRecordError
    head :service_unavailable
  end
end
