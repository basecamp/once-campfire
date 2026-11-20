require "rails_ext/time_limited_video_previewer"

ActiveSupport.on_load(:active_storage_blob) do
  ActiveStorage::DiskController.after_action only: :show do
    response.set_header("Cache-Control", "max-age=3600, public")
  end
end

Rails.application.configure do
  # A browser asks for a playing video piece by piece, and for every piece after the first it asks at the URL the
  # first request was redirected to. When that URL has expired the video stops: after a pause, or whenever a response
  # was cut short. So it lasts a day, the life of a page left open, instead of Rails' five minutes.
  config.active_storage.service_urls_expire_in = 1.day

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
