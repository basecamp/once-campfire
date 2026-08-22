class Oidc::FlowsController < ApplicationController
  allow_unauthenticated_access

  def show
    redirect_to new_session_url unless Oidc::Flow.pending_for?(cookies[Oidc::BROWSER_COOKIE])
  end

  def destroy
    canceled = Oidc::Flow.cancel! cookies[Oidc::BROWSER_COOKIE]
    session.delete Oidc::FLOW_STARTED_AT_SESSION_KEY
    session.delete Oidc::LINKING_INTENT_SESSION_KEY
    session.delete "omniauth.state"
    session.delete "omniauth.nonce"
    session.delete "omniauth.pkce.verifier"
    if canceled
      redirect_to new_session_url(oidc_retry: 1)
    else
      redirect_to root_url, alert: "No active single sign-on attempt was canceled. It may already have finished."
    end
  end
end
