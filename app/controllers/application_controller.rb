class ApplicationController < ActionController::Base
  include RequireOidcReadiness, AllowBrowser, Authentication, Authorization, BlockBannedRequests, SetCurrentRequest, SetPlatform, TrackedRoomVisit, VersionHeaders
  include Turbo::Streams::Broadcasts, Turbo::Streams::StreamName

  rescue_from ActionController::BadRequest, with: -> { head :bad_request }
  rescue_from ContentLimits::Exceeded, with: -> { head :content_too_large }
  rescue_from User::AuthorizationError, with: -> { head :forbidden }
end
