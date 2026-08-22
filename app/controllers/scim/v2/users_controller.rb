class Scim::V2::UsersController < Scim::BaseController
  FILTER_PATTERN = /\A(externalId|userName|id)\s+eq\s+"((?:[^"\\]|\\["\\])*)"\z/i
  MAXIMUM_OPERATIONS = 10

  SUBJECT_DEPROVISIONING_ID = Identity::SUBJECT_DEPROVISIONING_SCIM_ID

  before_action :set_identity, only: %i[ show update ]

  def index
    identity = identity_from_filter
    total_results = identity ? 1 : 0
    resources = if identity && requested_start_index == 1 && requested_count.positive?
      [ user_resource(identity) ]
    else
      []
    end

    render_scim({
      schemas: [ Scim::LIST_RESPONSE_SCHEMA ],
      totalResults: total_results,
      startIndex: requested_start_index,
      itemsPerPage: resources.length,
      Resources: resources
    })
  end

  def show
    render_scim user_resource(@identity)
  end

  def update
    validate_patch_request!
    @identity.user.deactivate_from_identity_provider!(identity: @identity, issuer: Scim.issuer)
    render_scim user_resource(@identity.reload)
  end

  def destroy
    if params[:id] == SUBJECT_DEPROVISIONING_ID
      deprovision_subject_without_existence_signal
    else
      identity = scim_identities.includes(:user).find_by!(scim_id: params[:id])
      identity.user.deactivate_from_identity_provider!(identity:, issuer: Scim.issuer)
    end
    head :no_content
  end

  private
    def set_identity
      @identity = scim_identities.includes(:user).find_by!(scim_id: params[:id])
    end

    def identity_from_filter
      attribute, value = parsed_identity_filter

      if attribute == "id"
        scim_identities.includes(:user).find_by(scim_id: value)
      else
        scim_identities.includes(:user).find_by(subject: value)
      end
    end

    def subject_from_deprovisioning_filter
      attribute, value = parsed_identity_filter
      unless attribute == "externalid"
        raise InvalidRequest.new(
          "Subject deprovisioning requires an externalId filter.", scim_type: "invalidFilter"
        )
      end

      value
    end

    def deprovision_subject_without_existence_signal
      Identity::Deprovisioning.deprovision!(
        issuer: Scim.issuer, subject: subject_from_deprovisioning_filter
      )
    end

    def parsed_identity_filter
      filter = params[:filter]
      match = filter.match(FILTER_PATTERN) if filter.is_a?(String) && filter.bytesize <= 1024
      unless match
        raise InvalidRequest.new("A stable identity filter is required.", scim_type: "invalidFilter")
      end

      attribute = match[1].downcase
      value = match[2].gsub(/\\(["\\])/, "\\1")
      if value.blank? || value.bytesize > Identity::MAXIMUM_IDENTIFIER_LENGTH
        raise InvalidRequest.new("The identity filter is invalid.", scim_type: "invalidFilter")
      end

      [ attribute, value ]
    end

    def requested_start_index
      @requested_start_index ||= integer_query_parameter(:startIndex, default: 1, minimum: 1, maximum: 1_000_000)
    end

    def requested_count
      @requested_count ||= integer_query_parameter(:count, default: 1, minimum: 0, maximum: 1_000)
    end

    def integer_query_parameter(name, default:, minimum:, maximum:)
      value = params[name]
      return default if value.nil?
      unless value.is_a?(String) && value.match?(/\A\d+\z/)
        raise InvalidRequest.new("Pagination is invalid.", scim_type: "invalidValue")
      end

      Integer(value, 10).presence_in(minimum..maximum) ||
        raise(InvalidRequest.new("Pagination is invalid.", scim_type: "invalidValue"))
    end

    def validate_patch_request!
      unless request.media_type.in?([ Scim::MEDIA_TYPE, "application/json" ])
        raise InvalidRequest.new("PATCH requires a SCIM JSON document.", scim_type: "invalidSyntax")
      end

      payload = request.request_parameters
      unless payload.is_a?(Hash) && payload.keys.sort == %w[ Operations schemas ] &&
          payload["schemas"] == [ Scim::PATCH_OPERATION_SCHEMA ]
        raise InvalidRequest.new("The PATCH document is invalid.", scim_type: "invalidSyntax")
      end

      operations = payload["Operations"]
      unless operations.is_a?(Array) && operations.length.between?(1, MAXIMUM_OPERATIONS) &&
          operations.all? { valid_deactivation_operation?(_1) }
        raise InvalidRequest.new("Only active=false is supported.", scim_type: "mutability")
      end
    end

    def valid_deactivation_operation?(operation)
      return false unless operation.is_a?(Hash) && operation.keys.all? { _1.in?(%w[ op path value ]) }
      return false unless operation["op"].is_a?(String) && operation["op"].casecmp?("replace")

      if operation.key?("path")
        operation["path"].is_a?(String) && operation["path"].casecmp?("active") &&
          operation["value"].equal?(false)
      else
        value = operation["value"]
        value.is_a?(Hash) && value.length == 1 &&
          value.keys.sole.is_a?(String) && value.keys.sole.casecmp?("active") &&
          value.values.sole.equal?(false)
      end
    end

    def scim_identities
      Identity.where(issuer: Scim.issuer)
    end

    def user_resource(identity)
      {
        schemas: [ Scim::USER_SCHEMA ],
        id: identity.scim_id,
        externalId: identity.subject,
        userName: identity.subject,
        active: identity.user.active? && !identity.provider_revoked_at?,
        meta: {
          resourceType: "User",
          created: identity.created_at.iso8601,
          lastModified: [ identity.updated_at, identity.user.updated_at ].max.iso8601,
          location: scim_v2_user_url(identity.scim_id)
        }
      }
    end

    def render_scim(payload)
      render json: payload, content_type: Scim::MEDIA_TYPE
    end
end
