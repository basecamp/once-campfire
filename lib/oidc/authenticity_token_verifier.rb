require "action_controller"

module Oidc
  class AuthenticityTokenVerifier
    def call(env)
      controller = ActionController::Base.new
      controller.set_request! ActionDispatch::Request.new(env)
      raise ActionController::InvalidAuthenticityToken unless controller.send(:verified_request?)
    end
  end
end
