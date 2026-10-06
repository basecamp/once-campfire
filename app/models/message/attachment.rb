module Message::Attachment
  extend ActiveSupport::Concern

  THUMBNAIL_MAX_WIDTH = 1200
  THUMBNAIL_MAX_HEIGHT = 800

  # Decoding a picture, or a video's frame, costs in proportion to its pixels, however small the file. The largest
  # phone photos have 200 million.
  THUMBNAIL_MAX_PIXELS = 250_000_000

  included do
    has_one_attached :attachment do |attachable|
      attachable.variant :thumb, resize_to_limit: [ THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT ]
      attachable.variant :poster, format: :webp, resize_to_limit: [ THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT ]
    end
  end

  module ClassMethods
    def create_with_attachment!(attributes)
      create!(attributes).tap(&:process_attachment)
    end
  end

  def attachment?
    attachment.attached?
  end

  def process_attachment
    ensure_attachment_analyzed
    process_attachment_thumbnail
  end

  private
    def ensure_attachment_analyzed
      attachment&.analyze
    end

    # A file that ffmpeg or libvips can't decode is still the message: post it without a preview.
    def process_attachment_thumbnail
      return if too_many_pixels_to_preview?

      case
      when attachment.video?
        attachment.preview(:poster).processed
      when attachment.representable?
        attachment.representation(:thumb).processed
      end
    rescue ActiveStorage::PreviewError, Vips::Error => error
      Rails.logger.warn "Posted #{attachment.filename} without a preview: #{error.class}: #{error.message.lines.first&.chomp}"
    end

    # Without a size, the analyzer couldn't read the file's header, and the previewer wouldn't either.
    def too_many_pixels_to_preview?
      if attachment.image? || attachment.video?
        width, height = attachment.metadata.values_at(:width, :height)
        width.nil? || height.nil? || width * height > THUMBNAIL_MAX_PIXELS
      end
    end
end
