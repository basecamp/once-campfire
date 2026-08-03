class Scim::V2::ServiceProviderConfigsController < Scim::BaseController
  def show
    render json: {
      schemas: [ Scim::SERVICE_PROVIDER_CONFIG_SCHEMA ],
      patch: { supported: true },
      bulk: { supported: false, maxOperations: 0, maxPayloadSize: 0 },
      filter: { supported: true, maxResults: 1 },
      changePassword: { supported: false },
      sort: { supported: false },
      etag: { supported: false },
      authenticationSchemes: [ {
        type: "oauthbearertoken",
        name: "Bearer Token",
        description: "Static bearer authentication",
        primary: true
      } ],
      meta: {
        resourceType: "ServiceProviderConfig",
        location: scim_v2_service_provider_config_url
      }
    }, content_type: Scim::MEDIA_TYPE
  end
end
