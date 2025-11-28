class Message < ApplicationRecord
  include Attachment, Broadcasts, Mentionee, Pagination, Searchable

  validate :attachment_size

  belongs_to :room, touch: true
  belongs_to :creator, class_name: "User", default: -> { Current.user }

  has_many :boosts, dependent: :destroy

  has_rich_text :body

  before_create -> { self.client_message_id ||= Random.uuid } # Bots don't care
  after_create_commit -> { room.receive(self) }

  scope :ordered, -> { order(:created_at) }
  scope :with_creator, -> { preload(creator: :avatar_attachment) }
  scope :with_attachment_details, -> {
    with_rich_text_body_and_embeds
    with_attached_attachment
      .includes(attachment_blob: :variant_records)
  }
  scope :with_boosts, -> { includes(boosts: :booster) }

  def plain_text_body
    body.to_plain_text.presence || attachment&.filename&.to_s || ""
  end

  def to_key
    [ client_message_id ]
  end

  def content_type
    case
    when attachment?    then "attachment"
    when sound.present? then "sound"
    else                     "text"
    end.inquiry
  end

  def sound
    plain_text_body.match(/\A\/play (?<name>\w+)\z/) do |match|
      Sound.find_by_name match[:name]
    end
  end

  private
    def attachment_size
      if attachment? && !ApplicationController.helpers.is_attachment_size_valid(attachment.blob.byte_size)
        errors.add(:attachment, "Attachment exceeds max size: #{ApplicationController.helpers.max_attachment_size_in_bytes}")
      end
    end
end
