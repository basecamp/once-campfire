module User::Avatar
  extend ActiveSupport::Concern

  included do
    has_one_attached :avatar do |attachable|
      attachable.variant :square, resize_to_limit: [ 512, 512 ], format: :webp
    end
  end

  class_methods do
    def from_avatar_token(sid)
      find_signed!(sid, purpose: :avatar)
    end
  end

  def avatar_token
    signed_id(purpose: :avatar)
  end

  def avatar_variant
    if avatar.variable?
      variant = avatar.variant(:square)
      variant.processed if variant.processed? || avatar_previewable?
    end
  end

  private
    # The variant is made in the request that first shows the avatar, so it gets the limit a message's preview has.
    def avatar_previewable?
      avatar.analyze unless avatar.analyzed?
      !Message::Attachment.too_many_pixels_to_preview?(avatar.blob)
    end
end
