class PollOption < ApplicationRecord
  belongs_to :poll
  has_many :votes, class_name: "PollVote", dependent: :destroy, inverse_of: :poll_option

  validates :body, presence: true, length: { maximum: Poll::OPTION_MAX_LENGTH }
  validates :position, presence: true
end
