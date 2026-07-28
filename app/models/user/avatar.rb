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
    avatar.variant(:square).processed if avatar.variable?
  end
end
