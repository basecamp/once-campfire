require "test_helper"
require "oidc/authenticity_token_verifier"

class Oidc::AuthenticityTokenVerifierTest < ActiveSupport::TestCase
  test "rejects a request without a Rails authenticity token" do
    previous_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    environment = Rack::MockRequest.env_for(
      "https://campfire.example.com/auth/openid_connect",
      method: "POST",
      "rack.session" => {}
    )

    assert_raises(ActionController::InvalidAuthenticityToken) do
      Oidc::AuthenticityTokenVerifier.new.call(environment)
    end
  ensure
    ActionController::Base.allow_forgery_protection = previous_forgery_protection
  end
end
