require "oidc/activation"
require "oidc/request_guard"

module RequireOidcReadiness
  extend ActiveSupport::Concern

  included do
    prepend_before_action :require_oidc_readiness
    rescue_from Oidc::PolicyUnavailable, with: :render_oidc_policy_unavailable
  end

  private
    def require_oidc_readiness
      if Oidc.rollback_prepared? && !request.path.in?(Oidc::RequestGuard::HEALTH_PATHS)
        render plain: "Campfire is prepared for rollback and is not accepting requests.", status: :service_unavailable
      elsif Oidc.required? && !Oidc::RequestGuard.maintenance_request?(request) && !Oidc::Activation.ready?
        render plain: "OIDC required mode is not ready. Run bin/rails oidc:check for details.", status: :service_unavailable
      end
    end

    def render_oidc_policy_unavailable
      render plain: Oidc::POLICY_UNAVAILABLE_MESSAGE, status: :service_unavailable
    end
end
