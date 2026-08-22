class Message < ApplicationRecord
  class ClientMessageIdConflict < StandardError; end
  ORIGIN_USER = "user"
  ORIGIN_BOT_API = "bot_api"
  ORIGIN_WEBHOOK_REPLY = "webhook_reply"
  ORIGINS = [ ORIGIN_USER, ORIGIN_BOT_API, ORIGIN_WEBHOOK_REPLY ].freeze

  include Attachment, Broadcasts, Mentionee, Pagination, Searchable

  belongs_to :room, touch: true
  belongs_to :creator, class_name: "User", default: -> { Current.user }

  has_many :boosts, dependent: :destroy
  has_many :message_effects, class_name: "Message::Effect"

  has_rich_text :body

  before_create -> { self.client_message_id ||= Random.uuid } # Bots don't care
  before_create :authorize_creator!
  after_create :create_reliable_effects
  after_create_commit :perform_reliable_effects
  before_destroy :create_destroy_effect
  after_destroy_commit :perform_destroy_effect
  before_validation :verify_body_size
  validate :body_or_attachment
  validate :client_message_id_within_limit
  validate :preserve_client_message_id, on: :update
  validate :preserve_origin, on: :update
  validates :origin, inclusion: { in: ORIGINS }

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
    [ room_id, client_message_id ]
  end

  def to_param
    id&.to_s
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

  def dispatch_pending_effects
    Message::Effect.dispatch_pending Message::Effect.pending.where(message_id: id)
  end

  def perform_reliable_effects
    Message::Effect::IMMEDIATE_EFFECTS.each do |effect|
      message_effects.pending.find_by(effect:)&.perform_safely
    end
    dispatch_pending_effects
  end

  def webhook_recipient_ids
    webhook_recipients.ids
  end

  def webhook_recipients
    return User.none if creator.bot?

    recipients = room.direct? ? room.users.active_bots : mentionees.active_bots
    recipients.where.not(id: creator_id)
  end

  def update_with_broadcast!(attributes, actor:, authenticated_bot_key: nil)
    authenticated_bot_key = authenticated_bot_key&.dup
    User::MutationFence.with(actor.id) do
      effect = transaction do
        message = self.class.lock.find(id)
        locked_actor = message.send :authorize_actor!, actor
        User.verify_bot_key! locked_actor, authenticated_bot_key if authenticated_bot_key
        message.update!(attributes)
        message.send :create_effect!, "broadcast_update", "broadcast_update:#{SecureRandom.uuid}"
      end
      effect.perform_safely
      reload
    end
  end

  def destroy_with_broadcast!(actor:, authenticated_bot_key: nil)
    authenticated_bot_key = authenticated_bot_key&.dup
    User::MutationFence.with(actor.id) do
      transaction do
        message = self.class.lock.find(id)
        locked_actor = message.send :authorize_actor!, actor
        User.verify_bot_key! locked_actor, authenticated_bot_key if authenticated_bot_key
        message.destroy!
      end
    end
    self
  end

  private
    def create_reliable_effects
      create_effect! "room_receive", "room_receive"
      create_effect! "broadcast_create", "broadcast_create"
      if origin == ORIGIN_USER && !creator.bot?
        create_effect! "webhook_fanout", "webhook_fanout"
      end
    end

    def create_destroy_effect
      effect = create_effect!("broadcast_destroy", "broadcast_destroy")
      @destroy_effect_id = effect.id
    end

    def perform_destroy_effect
      Message::Effect.find_by(id: @destroy_effect_id)&.perform_safely
    end

    def create_effect!(effect, deduplication_key)
      message_effects.create!(
        effect:, deduplication_key:, room_id:, message_client_id: client_message_id
      )
    end

    def authorize_creator!
      locked_creator = User.lock_room_member!(self.creator_id || creator.id, room_id)
      self.creator = locked_creator
    end

    def authorize_actor!(actor)
      locked_actor = User.lock_room_member!(actor, room_id)
      unless locked_actor.administrator? || locked_actor.id == creator_id
        raise User::AuthorizationError, "user cannot administer this message"
      end
      locked_actor
    end

    def verify_body_size
      ContentLimits.verify! body.to_s.bytesize,
        maximum: ContentLimits::MESSAGE_BODY_BYTES, description: "message body"
    end

    def body_or_attachment
      errors.add :base, "message must include text or an attachment" if body.blank? && !attachment.attached?
    end

    def client_message_id_within_limit
      if !client_message_id.nil? && client_message_id.empty?
        errors.add :client_message_id, "cannot be blank"
      elsif client_message_id && client_message_id.bytesize > ContentLimits::CLIENT_MESSAGE_ID_BYTES
        errors.add :client_message_id,
          "is too long (maximum is #{ContentLimits::CLIENT_MESSAGE_ID_BYTES} bytes)"
      end
    end

    def preserve_client_message_id
      errors.add :client_message_id, "cannot be changed" if will_save_change_to_client_message_id?
    end

    def preserve_origin
      errors.add :origin, "cannot be changed" if will_save_change_to_origin?
    end
end
