require "oidc/activation"

class Oidc::ReadinessController < ActionController::Base
  def show
    if Oidc.rollback_prepared?
      render json: { status: "not_ready" }, status: :service_unavailable
    elsif Oidc.enabled? &&
        (!Identity::Deprovisioning.ready? || !Oidc::SessionGeneration.ready? ||
          !Oidc::LogoutToken.ready? || !Oidc::Readiness.ready? || !User::MutationFence.ready?)
      render json: { status: "not_ready" }, status: :service_unavailable
    elsif !Oidc.required? || Oidc::Activation.ready?
      render json: { status: Oidc.enabled? ? "ready" : "disabled" }
    else
      render json: { status: "not_ready" }, status: :service_unavailable
    end
  rescue Oidc::PolicyUnavailable
    render json: { status: "not_ready" }, status: :service_unavailable
  end
end
