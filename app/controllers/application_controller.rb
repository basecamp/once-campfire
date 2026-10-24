class ApplicationController < ActionController::Base
  include AllowBrowser, Authentication, Authorization, BlockBannedRequests, SetCurrentRequest, SetPlatform, TrackedRoomVisit, VersionHeaders, CacheTimings, CachedResponses, InlineScriptHashes
  include Turbo::Streams::Broadcasts, Turbo::Streams::StreamName
end
