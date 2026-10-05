module Message::Attachment
  extend ActiveSupport::Concern

  THUMBNAIL_MAX_WIDTH = 1200
  THUMBNAIL_MAX_HEIGHT = 800

  included do
    has_one_attached :attachment do |attachable|
      attachable.variant :thumb, resize_to_limit: [ THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT ]
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
      case
      when attachment.video?
        attachment.preview(format: :webp).processed
      when attachment.representable?
        attachment.representation(:thumb).processed
      end
    rescue ActiveStorage::PreviewError, Vips::Error => error
      Rails.logger.warn "Posted #{attachment.filename} without a preview: #{error.class}: #{error.message.lines.first&.chomp}"
    end
end
