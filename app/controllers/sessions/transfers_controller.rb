class Sessions::TransfersController < ApplicationController
  TRANSFER_INTENT_SESSION_KEY = "credential_intent.transfer"

  allow_unauthenticated_access

  def show
    return redirect_to new_session_path, alert: "Session transfer is unavailable while single sign-on is required." if Oidc.required?

    @transfer_ready = CredentialIntent.valid_transfer?(session[TRANSFER_INTENT_SESSION_KEY])
    session.delete TRANSFER_INTENT_SESSION_KEY unless @transfer_ready
  end

  def intent
    return head :forbidden if Oidc.required?

    session[TRANSFER_INTENT_SESSION_KEY] = CredentialIntent.exchange_transfer!(params[:token])
    redirect_to session_transfer_path
  rescue CredentialIntent::Invalid
    session.delete TRANSFER_INTENT_SESSION_KEY
    redirect_to session_transfer_path, alert: "That session transfer link is invalid or has already been used."
  end

  def update
    return head :forbidden if Oidc.required?

    token = session.delete TRANSFER_INTENT_SESSION_KEY
    user = CredentialIntent.consume_transfer!(token) { _1 }
    start_new_session_for user, authentication_method: "transfer"
    redirect_to post_authenticating_url
  rescue CredentialIntent::Invalid
    head :bad_request
  rescue Oidc::Activation::Error, ActiveRecord::ActiveRecordError
    head :service_unavailable
  end
end
