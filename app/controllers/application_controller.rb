class ApplicationController < ActionController::Base
  include AllowBrowser, Authentication, Authorization, BlockBannedRequests, SetCurrentRequest, SetPlatform, TrackedRoomVisit, VersionHeaders, CachedResponses, FragmentCaching
  include Turbo::Streams::Broadcasts, Turbo::Streams::StreamName
end
