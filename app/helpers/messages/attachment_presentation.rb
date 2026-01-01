class Messages::AttachmentPresentation
  def initialize(message, context:)
    @message, @context = message, context
  end

  def render
    if message.attachment.attached?
      if message.attachment.previewable? || message.attachment.variable? || message.attachment.audio?
        render_preview
      else
        render_link
      end
    end
  end

  private
    attr_reader :message, :context
    delegate :tag, :link_to, :broadcast_image_tag, :rails_blob_path, :url_for, to: :context

    def render_preview
      if message.attachment.video?
        video_preview_tag
      elsif message.attachment.audio?
        audio_preview_tag
      else
        lightboxed_image_preview_tag
      end
    end

    def video_preview_tag
      width, height = preview_dimensions

      inline_media_dimension_constraints(width, height) do
        tag.video \
          src: rails_blob_path(message.attachment), poster: url_for(message.attachment.preview(format: :webp, resize_to_limit: [ Message::THUMBNAIL_MAX_WIDTH, Message::THUMBNAIL_MAX_HEIGHT ])),
          controls: true, preload: :none, width: "100%", height: "100%", class: "message__attachment"
      end
    end

    def audio_preview_tag
      tag.div class: "audio-message-container", data: { controller: "sound", sound_url_value: rails_blob_path(message.attachment), sound_audio_message_duration_value: message.attachment.metadata["duration"].to_i }  do
        tag.div class: "sound audio-message" do
          tag.button("🔊", class: "btn btn--plain audio-message-btn", data: { action: "sound#playAndAnimate" }) + sound_preview_tag
        end + tag.div(message.attachment.metadata["duration"].to_i, class: "audio-message-metadata", data: { sound_target: "audioMessageMetadata" })
      end
    end

    def generate_sound_bars_tags
      html_element = ""

      11.times do |i|
        html_element << tag.div(class: "sound-bar sound-bar-#{i}")
      end

      html_element.html_safe
    end

    def sound_preview_tag
      tag.div(class: "sound-bar-container", data: { sound_target: "soundBarContainer" }) do
        generate_sound_bars_tags
      end
    end

    def lightboxed_image_preview_tag
      width, height = preview_dimensions

      inline_media_dimension_constraints(width, height) do
        lightbox_link do
          broadcast_image_tag message.attachment.representation(:thumb), width: width, height: height, class: "message__attachment", loading: "lazy"
        end
      end
    end

    def inline_media_dimension_constraints(width, height, &)
      if width && height
        aspect_ratio = (width / height.to_f)

        tag.div class: "max-inline-size center flex overflow-clip", style: "width: #{width / 2}px; aspect-ratio: #{aspect_ratio};", &
      else
        tag.div class: "max-inline-size center overflow-clip", &
      end
    end

    def preview_dimensions
      width = message.attachment.metadata[:width]
      height = message.attachment.metadata[:height]

      case
      when width.nil? || height.nil?
        [ nil, nil ]
      when width <= Message::THUMBNAIL_MAX_WIDTH && height <= Message::THUMBNAIL_MAX_HEIGHT
        [ width, height ]
      else
        width_factor = Message::THUMBNAIL_MAX_WIDTH.to_f / width
        height_factor = Message::THUMBNAIL_MAX_HEIGHT.to_f / height
        scale_factor = [ width_factor, height_factor ].min

        [ width * scale_factor, height * scale_factor ]
      end
    end

    def render_link
      tag.div class: "flex-inline align-center gap-half" do
        broadcast_image_tag("common-file-text.svg", size: 22, class: "colorize--black", aria: { hidden: "true" }) +
          tag.span(filename) + download_link + share_button
      end
    end

    def lightbox_link(&)
      link_to rails_blob_path(message.attachment), class: "flex", data: {
        lightbox_target: "image", action: "lightbox#open", lightbox_url_value: download_url }, &
    end

    def download_link
      link_to download_url, class: "btn message__action-btn hide-in-ios-pwa", style: "--width: auto;" do
        broadcast_image_tag("download.svg", aria: { hidden: "true" }, size: 20) + tag.span("Download #{ filename }", class: "for-screen-reader")
      end
    end

    def share_button
      tag.button class: "btn message__action-btn", style: "--width: auto;", data: { controller: "web-share", action: "web-share#share", web_share_files_value: download_url } do
        broadcast_image_tag("share.svg", aria: { hidden: "true" }, size: 20) + tag.span("Share #{ filename }", class: "for-screen-reader")
      end
    end

    def filename
      message.attachment.filename.to_s
    end

    def download_url
      rails_blob_path message.attachment, disposition: "attachment", only_path: true
    end
end
