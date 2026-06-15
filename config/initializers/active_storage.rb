ActiveSupport.on_load(:active_storage_blob) do
  ActiveStorage::DiskController.after_action only: :show do
    response.set_header("Cache-Control", "max-age=3600, public")
  end

  # Gate the ActiveStorage write path behind app authentication. These endpoints
  # ship unauthenticated by Rails default; Campfire never uses direct upload for
  # legit attachments (those go through MessagesController#create, and Trix file
  # drops are disabled in the composer). Requiring a session on the write actions
  # blocks anonymous blob writes and disk-fill while leaving blob serving public.
  #
  # ActiveStorage controllers live in ActiveStorage::Engine, so they see the
  # engine's url helpers, not the main app's. Include the application helpers
  # first so Authentication#request_authentication can redirect to new_session_url.
  ActiveStorage::DirectUploadsController.include Rails.application.routes.url_helpers
  ActiveStorage::DirectUploadsController.include Authentication # only action: #create

  ActiveStorage::DiskController.include Rails.application.routes.url_helpers
  ActiveStorage::DiskController.include Authentication
  ActiveStorage::DiskController.skip_before_action :require_authentication, :deny_bots, only: :show
end
