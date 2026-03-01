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

    def process_attachment_thumbnail
      case
      when attachment.video?
        attachment.preview(format: :webp).processed
      when attachment.representable?
        attachment.representation(:thumb).processed
      end
    rescue LoadError, StandardError => e
      Rails.logger.warn \
        "Skipping attachment thumbnail generation for message #{id || "new"}: #{e.class} #{e.message}"
    end
end
