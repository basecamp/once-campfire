class Poll < ApplicationRecord
  QUESTION_MAX_LENGTH = 280
  OPTION_MAX_LENGTH = 120
  MIN_OPTIONS = 2
  MAX_OPTIONS = 10

  belongs_to :message, touch: true
  has_many :options, -> { order(:position) }, class_name: "PollOption", dependent: :destroy, inverse_of: :poll
  has_many :votes, class_name: "PollVote", dependent: :destroy, inverse_of: :poll

  has_rich_text :question

  accepts_nested_attributes_for :options, allow_destroy: true

  validates :message_id, uniqueness: true
  validates :multi_select, inclusion: { in: [ true, false ] }
  validate :question_presence_and_length
  validate :option_count

  def closed?
    closed_at.present?
  end

  def structure_editable?
    open? && votes.none?
  end

  def close!
    update!(closed_at: Time.current)
  end

  def open?
    !closed?
  end

  def question_plain_text
    question.to_plain_text.squish
  end

  private
    def question_presence_and_length
      plain = question_plain_text
      errors.add(:question, :blank) if plain.blank?
      if plain.length > QUESTION_MAX_LENGTH
        errors.add(:question, "is too long (maximum is #{QUESTION_MAX_LENGTH} characters)")
      end
    end

    def option_count
      kept_options = options.reject(&:marked_for_destruction?)
      if kept_options.size < MIN_OPTIONS || kept_options.size > MAX_OPTIONS
        errors.add(:options, "must have between #{MIN_OPTIONS} and #{MAX_OPTIONS} options")
      end
    end
end
