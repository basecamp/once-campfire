require "security_endpoint_request_guard"

Rails.application.config.middleware.insert_before Rack::MethodOverride, SecurityEndpointBodyLimiter
Rails.application.config.middleware.insert_after ActionDispatch::RemoteIp, SecurityEndpointRequestGuard
