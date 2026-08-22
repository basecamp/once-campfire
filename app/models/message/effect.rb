class Message::Effect < ApplicationRecord
  include ReliableWork

  EFFECTS = %w[
    room_receive broadcast_create broadcast_update broadcast_destroy
    push_delivery presence_reconcile webhook_fanout bot_webhook
  ].freeze
  IMMEDIATE_EFFECTS = %w[
    room_receive broadcast_create broadcast_update broadcast_destroy webhook_fanout
  ].freeze
  RECIPIENT_EFFECTS = %w[ push_delivery presence_reconcile bot_webhook ].freeze
  MAXIMUM_FANOUT_BATCH_SIZE = ReliableWork::DISPATCH_BATCH_SIZE
  RECIPIENT_FANOUT_BATCH_SIZE = Integer(
    ENV.fetch("MESSAGE_RECIPIENT_FANOUT_BATCH_SIZE", 100).to_s, 10
  )
  BOT_FANOUT_BATCH_SIZE = Integer(
    ENV.fetch("MESSAGE_BOT_FANOUT_BATCH_SIZE", 25).to_s, 10
  )
  unless [ RECIPIENT_FANOUT_BATCH_SIZE, BOT_FANOUT_BATCH_SIZE ].all? {
      _1.between?(1, MAXIMUM_FANOUT_BATCH_SIZE)
    }
    raise ArgumentError,
      "message fanout batch sizes must be between 1 and #{MAXIMUM_FANOUT_BATCH_SIZE}"
  end
  TERMINAL_RETENTION = 1.day
  TERMINAL_PRUNE_BATCH_SIZE = 10_000
  JOB_CLASS = MessageEffectJob

  belongs_to :message, optional: true

  validates :effect, inclusion: { in: EFFECTS }
  validates :deduplication_key, :room_id, :message_client_id, presence: true
  validate :message_client_id_within_limit
  validates :recipient_id, presence: true, if: -> { effect.in?(RECIPIENT_EFFECTS) }
  validates :recipient_id, absence: true, unless: -> { effect.in?(RECIPIENT_EFFECTS) }
  validates :webhook_id, :webhook_generation, :delivery_id, presence: true, if: -> { effect == "bot_webhook" }
  validates :webhook_id, :webhook_generation, :delivery_id, absence: true, unless: -> { effect == "bot_webhook" }
  validates :presence_generation, presence: true, if: -> { effect == "presence_reconcile" }
  validates :presence_generation, absence: true, unless: -> { effect == "presence_reconcile" }
  validates :delivery_id, uniqueness: true, allow_nil: true, format: { with: Webhook::UUID_PATTERN }

  scope :pending, -> { where(completed_at: nil, canceled_at: nil, failed_at: nil) }
  scope :dead_lettered, -> { where.not(failed_at: nil) }

  class << self
    def prune_terminal!(before: TERMINAL_RETENTION.ago, limit: TERMINAL_PRUNE_BATCH_SIZE)
      ids = where(failed_at: nil)
        .where("completed_at < :before OR canceled_at < :before", before:)
        .order(Arel.sql("COALESCE(completed_at, canceled_at) ASC"), :id)
        .limit(limit).ids
      where(id: ids).delete_all
    end

    def advance_presence_reconciliation_for(membership)
      now = Time.current
      effect_ids = transaction do
        current_membership = Membership.lock.find_by(id: membership.id)
        next [] unless current_membership && !current_membership.connected?

        effects = pending.where(
          effect: "presence_reconcile", recipient_id: current_membership.id,
          presence_generation: current_membership.presence_generation
        )
        effects.where("next_attempt_at > ?", now).update_all(next_attempt_at: now, updated_at: now)
        dispatchable(effects, now:).limit(ReliableWork::DISPATCH_BATCH_SIZE).ids
      end

      ActiveRecord.after_all_transactions_commit do
        dispatch_pending pending.where(id: effect_ids)
      end
    end
  end

  def perform!(lease_token)
    return false unless claim_for_processing!(lease_token)

    outcome = case effect
    when "room_receive"
      receive_message
    when "broadcast_create"
      message&.broadcast_create
    when "broadcast_update"
      message&.broadcast_update
    when "broadcast_destroy"
      broadcast_destroy
    when "push_delivery"
      deliver_push
    when "presence_reconcile"
      reconcile_presence
    when "webhook_fanout"
      create_webhook_effects
    when "bot_webhook"
      deliver_webhook
    end

    if outcome == :continue
      continued = release_for_continuation!(lease_token)
      dispatch_safely if continued
      return continued
    end

    completed = outcome == :cancel ? cancel!(lease_token) : complete!(lease_token)
    dispatch_recipient_effects if completed && effect.in?(%w[ room_receive webhook_fanout ])
    completed
  rescue StandardError => error
    mark_retry_scheduled(error) if release_for_retry!(lease_token, error)
    raise
  end

  def perform_safely(lease_token = nil)
    lease_token ||= acquire_lease
    return false unless lease_token

    perform! lease_token
  rescue StandardError => error
    Rails.logger.error "Message effect failed effect_id=#{id} effect=#{effect} error=#{error.class.name}"
    false
  end

  def dispatch_after_create_commit?
    !effect.in?(IMMEDIATE_EFFECTS) && effect != "presence_reconcile"
  end

  private
    def message_client_id_within_limit
      if message_client_id && message_client_id.bytesize > ContentLimits::CLIENT_MESSAGE_ID_BYTES
        errors.add :message_client_id,
          "is too long (maximum is #{ContentLimits::CLIENT_MESSAGE_ID_BYTES} bytes)"
      end
    end

    def receive_message
      return unless message

      now = Time.current
      recipient_effect_ids, more = self.class.transaction do
        existing_recipients = self.class.where(
          message_id:, effect: "presence_reconcile"
        ).select(:recipient_id)
        recipients = message.room.receive(message).where.not(id: existing_recipients)
          .order(:id).limit(RECIPIENT_FANOUT_BATCH_SIZE + 1)
          .pluck(:id, :connected_at, :presence_generation)
        batch = recipients.first(RECIPIENT_FANOUT_BATCH_SIZE)
        ids = batch.map do |membership_id, connected_at, presence_generation|
          create_recipient_effect(
            "presence_reconcile", membership_id,
            presence_generation:,
            next_attempt_at: connected_at ?
              connected_at + Membership::Connectable::CONNECTION_TTL + 1.second : now
          ).id
        end
        [ ids, recipients.size > batch.size ]
      end

      perform_due_recipient_effects(recipient_effect_ids, now:)
      dispatch_recipient_effects recipient_effect_ids
      :continue if more
    end

    def create_webhook_effects
      return unless message

      recipient_effect_ids, more = self.class.transaction do
        existing_recipients = self.class.where(
          message_id:, effect: "bot_webhook"
        ).select(:recipient_id)
        recipients = message.webhook_recipients.joins(:webhook)
          .where.not(id: existing_recipients).order("users.id")
          .limit(BOT_FANOUT_BATCH_SIZE + 1)
          .pluck("users.id", "webhooks.id", "webhooks.delivery_generation")
        batch = recipients.first(BOT_FANOUT_BATCH_SIZE)
        ids = batch.map do |bot_id, webhook_id, webhook_generation|
          create_recipient_effect(
            "bot_webhook", bot_id,
            webhook_id:,
            webhook_generation:,
            delivery_id: SecureRandom.uuid
          ).id
        end
        [ ids, recipients.size > batch.size ]
      end

      dispatch_recipient_effects recipient_effect_ids
      :continue if more
    end

    def create_recipient_effect(effect, recipient_id, **attributes)
      self.class.create_or_find_by!(message_id:, deduplication_key: "#{effect}:#{recipient_id}") do |work|
        work.effect = effect
        work.recipient_id = recipient_id
        work.room_id = room_id
        work.message_client_id = message_client_id
        work.assign_attributes attributes
      end
    end

    def dispatch_recipient_effects(effect_ids = nil)
      effects = self.class.pending.where(message_id:, effect: RECIPIENT_EFFECTS)
      effects = effects.where(id: effect_ids) if effect_ids
      self.class.dispatch_pending effects
    end

    def perform_due_recipient_effects(effect_ids, now:)
      effects = self.class.pending.where(id: effect_ids, effect: "presence_reconcile")
      disconnected_at_same_generation = <<~SQL
        EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.id = message_effects.recipient_id
            AND memberships.presence_generation = message_effects.presence_generation
            AND (memberships.connected_at IS NULL OR memberships.connected_at < ?)
        )
      SQL
      effects.where("next_attempt_at > ?", now).where(
        disconnected_at_same_generation, now - Membership::Connectable::CONNECTION_TTL
      ).update_all(next_attempt_at: now, updated_at: now)
      effect_ids = self.class.dispatchable(effects, now:).limit(RECIPIENT_FANOUT_BATCH_SIZE).ids
      effect_ids.each { self.class.find_by(id: _1)&.perform_safely }
    end

    def deliver_push
      return unless message

      Room::MessagePusher.new(room: message.room, message:).push_to recipient_id
    end

    def reconcile_presence
      return :cancel unless message

      result = self.class.transaction do
        membership = Membership.lock.find_by(id: recipient_id, room_id:)
        next :cancel unless membership && !membership.involved_in_invisible? && membership.user_id != message.creator_id
        next :cancel unless User.active.exists?(id: membership.user_id)
        next :cancel unless membership.presence_generation == presence_generation
        next :cancel if membership.connected?

        unread_at = [ membership.unread_at, message.created_at ].compact.max
        membership.update_columns(unread_at:, updated_at: Time.current)
        if membership.involved_in_everything? ||
            (membership.involved_in_mentions? && message.mentionees.exists?(id: membership.user_id))
          Push::Subscription.with_current_session.where(user_id: membership.user_id).ids.each do |subscription_id|
            create_recipient_effect "push_delivery", subscription_id
          end
        end
        membership.user_id
      end
      return :cancel if result == :cancel

      UnreadRoomsChannel.broadcast_to User.find(result), { roomId: room_id }
      nil
    end

    def deliver_webhook
      User::MutationFence.with(recipient_id) do
        delivery = authorized_webhook_delivery
        next :cancel unless delivery
        webhook, current_message = delivery

        webhook.deliver current_message, delivery_id:
      end
    end

    def authorized_webhook_delivery
      self.class.transaction do
        current_message = Message.lock.find_by(id: message_id, room_id:)
        next unless current_message
        next if current_message.creator.bot?
        bot = User.active_bots.lock.find_by(id: recipient_id)
        next unless bot && bot.id != current_message.creator_id

        membership = Membership.lock.find_by(room_id:, user_id: bot.id)
        next unless membership
        next unless current_message.room.direct? || current_message.mentionees.exists?(id: bot.id)

        webhook = Webhook.lock.find_by(
          id: webhook_id, user_id: bot.id, delivery_generation: webhook_generation
        )
        [ webhook, current_message ] if webhook
      end
    end

    def cancel!(token)
      now = Time.current
      self.class.pending.where(id:, lease_token: token).update_all(
        canceled_at: now, lease_token: nil, enqueued_at: nil, started_at: nil,
        next_attempt_at: nil, updated_at: now
      ) == 1
    end

    def broadcast_destroy
      if room = Room.find_by(id: room_id)
        Message.broadcast_destroy room, message_client_id
      end
    end
end
