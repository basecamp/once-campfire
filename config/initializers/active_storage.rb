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

  # Blob serving (#show) stays public so signed-token attachment URLs keep
  # resolving for unauthenticated and bot clients alike.
  ActiveStorage::DiskController.allow_unauthenticated_access only: :show
  ActiveStorage::DiskController.allow_bot_access only: :show

  # Including Authentication re-adds protect_from_forgery, but Active Storage's
  # direct-upload service PUT (#update) carries only signed service headers and
  # no authenticity token. Re-exempt it from CSRF so authenticated uploads can
  # still store bytes; the signed URL token and the session check remain.
  ActiveStorage::DiskController.skip_forgery_protection only: :update
end
