# Active Storage mounts its direct-upload write endpoints
# (POST /rails/active_storage/direct_uploads and the disk-service PUT) on
# framework controllers that inherit from ActiveStorage::BaseController, so
# they never pass through ApplicationController's require_authentication.
# Campfire uploads attachments through MessagesController instead and does not
# use direct uploads at all, leaving these endpoints reachable by anyone who
# can read the public login page. Require a valid Campfire session before an
# anonymous caller can allocate a Blob or persist bytes to disk.
#
# Each controller is extended as it loads, and again whenever it reloads,
# rather than loaded at boot to be extended.
Rails.autoloaders.main.on_load("ActiveStorage::BaseController") do |controller|
  controller.forgery_protection_verification_strategy = :header_only
end

Rails.autoloaders.main.on_load("ActiveStorage::DirectUploadsController") do |controller|
  controller.include ActiveStorageAuthentication
  controller.before_action :require_active_storage_authentication
end

Rails.autoloaders.main.on_load("ActiveStorage::DiskController") do |controller|
  controller.include ActiveStorageAuthentication
  controller.before_action :require_active_storage_authentication, only: :update
end
