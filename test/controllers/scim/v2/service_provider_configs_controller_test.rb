require "test_helper"

class Scim::V2::ServiceProviderConfigsControllerTest < ActionDispatch::IntegrationTest
  setup do
    configure_oidc
    configure_scim
  end

  test "advertises only the supported authenticated deprovisioning capabilities" do
    get scim_v2_service_provider_config_path, headers: scim_headers

    assert_response :success
    assert_equal Scim::MEDIA_TYPE, response.media_type
    body = JSON.parse(response.body)
    assert_equal true, body.dig("patch", "supported")
    assert_equal false, body.dig("bulk", "supported")
    assert_equal false, body.dig("changePassword", "supported")
    assert_equal "oauthbearertoken",
      body.fetch("authenticationSchemes").sole.fetch("type")
  end
end
