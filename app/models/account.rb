class Account < ApplicationRecord
  include Joinable

  has_one_attached :logo do |attachable|
    attachable.variant :large, resize_to_limit: [ 512, 512 ], format: :png
    attachable.variant :small, resize_to_limit: [ 192, 192 ], format: :png
  end

  has_json :settings, restrict_room_creation_to_administrators: false

  def logo_variant(size)
    if logo.variable?
      variant = logo.variant(size)
      variant.processed if variant.processed? || logo_previewable?
    end
  end

  private
    # The variant is made in the request that first shows the logo, so it gets the limit a message's preview has.
    def logo_previewable?
      logo.analyze unless logo.analyzed?
      !Message::Attachment.too_many_pixels_to_preview?(logo.blob)
    end
end
