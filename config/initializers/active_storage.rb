require "rails_ext/time_limited_video_previewer"

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

Rails.application.configure do
  # Rails' filter takes the second of the frames it selects (the first one, keyframes, scene changes), so a video
  # with a single keyframe and no scene change is decoded to its end. Selecting any frame from 5 seconds on stops
  # it there.
  config.active_storage.video_preview_arguments =
    "-vf 'select=eq(n\\,0)+eq(key\\,1)+gt(scene\\,0.015)+gte(t\\,5),loop=loop=-1:size=2,trim=start_frame=1'" \
    " -frames:v 1 -f image2"

  config.active_storage.previewers = config.active_storage.previewers.map do |previewer|
    previewer == ActiveStorage::Previewer::VideoPreviewer ? TimeLimitedVideoPreviewer : previewer
  end
end
