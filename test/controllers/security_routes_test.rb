require "test_helper"

class SecurityRoutesTest < ActiveSupport::TestCase
  test "OIDC and SCIM routes do not recognize format suffixes" do
    routes = Rails.application.routes
    {
      post: %w[
        /auth/openid_connect.json
        /auth/openid_connect/backchannel_logout.json
      ],
      get: %w[
        /auth/openid_connect/callback.json
        /auth/failure.json
        /oidc_link.json
        /oidc_flow.json
        /scim/v2/ServiceProviderConfig.json
        /scim/v2/Users.json
        /up/oidc.json
        /up/scim.json
      ]
    }.each do |method, paths|
      paths.each do |path|
        assert_raises(ActionController::RoutingError, path) do
          routes.recognize_path(path, method:)
        end
      end
    end
  end

  test "canonical SCIM member routes do not parse an identifier as a format" do
    uuid = "00000000-0000-0000-0000-000000000000"
    parameters = Rails.application.routes.recognize_path("/scim/v2/Users/#{uuid}", method: :get)

    assert_equal "scim/v2/users", parameters.fetch(:controller)
    assert_equal "show", parameters.fetch(:action)
    assert_equal uuid, parameters.fetch(:id)
    assert_not parameters.key?(:format)
  end
end
