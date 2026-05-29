class PollVote < ApplicationRecord
  belongs_to :poll
  belongs_to :poll_option
  belongs_to :voter, class_name: "User"

  after_commit -> { poll.message.touch }

  validates :poll_option_id, uniqueness: { scope: :voter_id }
  validate :option_belongs_to_poll

  private
    def option_belongs_to_poll
      return if poll_option.blank? || poll.blank?
      errors.add(:poll_option, "must belong to poll") if poll_option.poll_id != poll_id
    end
end
