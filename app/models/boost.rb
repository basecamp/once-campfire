class Boost < ApplicationRecord
  # Matches the maxlength on the boost form, which was the only limit until bots
  # could post a raw request body as boost content.
  MAX_CONTENT_LENGTH = 16

  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User", default: -> { Current.user }

  validates :content, presence: true, length: { maximum: MAX_CONTENT_LENGTH }

  scope :ordered, -> { order(:created_at) }
end
