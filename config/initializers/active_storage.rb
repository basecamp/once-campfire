require "rails_ext/time_limited_video_previewer"

ActiveSupport.on_load(:active_storage_blob) do
  ActiveStorage::DiskController.after_action only: :show do
    response.set_header("Cache-Control", "max-age=3600, public")
  end
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
