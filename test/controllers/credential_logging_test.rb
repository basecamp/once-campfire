require "test_helper"

class CredentialLoggingTest < ActiveSupport::TestCase
  test "browser secrets are filtered from parameters and absent from request paths" do
    secret = "private-browser-credential"
    env = Rack::MockRequest.env_for(
      "/join/intent", method: "POST", input: URI.encode_www_form(token: secret),
      "CONTENT_TYPE" => "application/x-www-form-urlencoded"
    )
    env["action_dispatch.parameter_filter"] = Rails.application.config.filter_parameters
    request = ActionDispatch::Request.new(env)

    assert_equal "/join/intent", request.filtered_path
    assert_equal "[FILTERED]", request.filtered_parameters.fetch("token")
    assert_not_includes request.filtered_path, secret
  end

  test "authorization headers are filtered from diagnostic environments" do
    secret = "Bearer persistent-bot-credential"
    env = Rack::MockRequest.env_for("/rooms/1/bot/messages", "HTTP_AUTHORIZATION" => secret)
    env["action_dispatch.parameter_filter"] = Rails.application.config.filter_parameters

    assert_equal "[FILTERED]", ActionDispatch::Request.new(env).filtered_env.fetch("HTTP_AUTHORIZATION")
  end

  test "OIDC logout tokens are filtered from form bodies and rejected query diagnostics" do
    secret = "signed.logout.token"
    env = Rack::MockRequest.env_for(
      "/auth/openid_connect/backchannel_logout?logout_token=#{secret}",
      method: "POST", input: URI.encode_www_form(logout_token: secret),
      "CONTENT_TYPE" => "application/x-www-form-urlencoded"
    )
    env["action_dispatch.parameter_filter"] = Rails.application.config.filter_parameters
    request = ActionDispatch::Request.new(env)

    assert_equal "[FILTERED]", request.filtered_parameters.fetch("logout_token")
    assert_not_includes request.filtered_path, secret
  end

  test "SCIM filter values are redacted from Rails diagnostics" do
    subject = "sensitive-provider-subject"
    env = Rack::MockRequest.env_for(
      "/scim/v2/Users?#{URI.encode_www_form(filter: %(externalId eq "#{subject}"))}"
    )
    env["action_dispatch.parameter_filter"] = Rails.application.config.filter_parameters
    request = ActionDispatch::Request.new(env)

    assert_equal "[FILTERED]", request.filtered_parameters.fetch("filter")
    assert_not_includes request.filtered_path, subject
  end
end
