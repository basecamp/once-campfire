class Account < ApplicationRecord
  include Joinable

  has_one_attached :logo do |attachable|
    attachable.variant :large, resize_to_limit: [ 512, 512 ], format: :png
    attachable.variant :small, resize_to_limit: [ 192, 192 ], format: :png
  end

  has_json :settings, restrict_room_creation_to_administrators: false

  def logo_variant(size)
    logo.variant(size).processed if logo.variable?
  end
end
