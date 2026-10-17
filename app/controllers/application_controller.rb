class ApplicationController < ActionController::Base
  include AllowBrowser, Authentication, Authorization, BlockBannedRequests, SetCurrentRequest, SetPlatform, TrackedRoomVisit, VersionHeaders, InlineScriptHashes
  include Turbo::Streams::Broadcasts, Turbo::Streams::StreamName
end
