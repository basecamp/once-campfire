class PollVote < ApplicationRecord
  belongs_to :poll
  belongs_to :poll_option
  belongs_to :voter, class_name: "User"

  after_create_commit :touch_message
  after_update_commit :touch_message
  after_destroy_commit :touch_message_if_poll_exists

  validates :poll_option_id, uniqueness: { scope: :voter_id }
  validate :option_belongs_to_poll

  private
    def touch_message
      poll.message.touch
    end

    def touch_message_if_poll_exists
      Poll.find_by(id: poll_id)&.message&.touch
    end

    def option_belongs_to_poll
      return if poll_option.blank? || poll.blank?
      errors.add(:poll_option, "must belong to poll") if poll_option.poll_id != poll_id
    end
end
