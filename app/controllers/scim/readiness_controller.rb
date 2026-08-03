class Scim::ReadinessController < ActionController::API
  def show
    if !Scim.enabled?
      render json: { status: "disabled" }
    elsif Scim.ready?
      render json: { status: "ready" }
    else
      render json: { status: "not_ready" }, status: :service_unavailable
    end
  end
end
