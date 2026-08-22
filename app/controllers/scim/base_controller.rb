class Scim::BaseController < ActionController::API
  class InvalidRequest < StandardError
    attr_reader :scim_type

    def initialize(message = "The request is invalid.", scim_type: "invalidValue")
      @scim_type = scim_type
      super(message)
    end
  end

  before_action :disable_storage, :require_scim_enabled, :authenticate_scim, :require_scim_ready

  rescue_from InvalidRequest, with: :render_invalid_request
  rescue_from ActionDispatch::Http::Parameters::ParseError, JSON::ParserError,
    with: :render_malformed_request
  rescue_from User::MutationFence::Unavailable, with: :render_unavailable
  rescue_from ActiveRecord::ActiveRecordError, with: :render_unavailable
  rescue_from ActiveRecord::RecordInvalid, with: :render_mutability_conflict
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  private
    def require_scim_enabled
      render_scim_error :not_found, detail: "Resource not found." unless Scim.enabled?
    end

    def disable_storage
      response.set_header "Cache-Control", "no-store"
    end

    def require_scim_ready
      render_scim_error :service_unavailable, detail: "Service is unavailable." unless Scim.ready?
    end

    def authenticate_scim
      return if Scim.authorized?(request.authorization)

      response.set_header "WWW-Authenticate", 'Bearer realm="SCIM"'
      render_scim_error :unauthorized, detail: "Authentication is required."
    end

    def render_invalid_request(error)
      render_scim_error :bad_request, scim_type: error.scim_type, detail: error.message
    end

    def render_malformed_request
      render_scim_error :bad_request, scim_type: "invalidSyntax", detail: "The request is malformed."
    end

    def render_not_found
      render_scim_error :not_found, detail: "Resource not found."
    end

    def render_mutability_conflict(error)
      log_failure "mutability", error
      render_scim_error :conflict, scim_type: "mutability", detail: "Resource cannot be deactivated."
    end

    def render_unavailable(error)
      log_failure "unavailable", error
      render_scim_error :service_unavailable, detail: "Service is unavailable."
    end

    def render_scim_error(status, scim_type: nil, detail:)
      payload = {
        schemas: [ Scim::ERROR_SCHEMA ],
        status: Rack::Utils.status_code(status).to_s,
        detail:
      }
      payload[:scimType] = scim_type if scim_type
      render json: payload, status:, content_type: Scim::MEDIA_TYPE
    end

    def log_failure(reason, error)
      Rails.logger.warn(
        "SCIM request rejected request_id=#{request.request_id} " \
          "reason=#{reason} error=#{error.class.name}"
      )
    end
end
