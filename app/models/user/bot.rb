module User::Bot
  extend ActiveSupport::Concern

  included do
    scope :active_bots, -> { active.where(role: :bot) }
    scope :without_bots, -> { where.not(role: :bot) }
    has_one :webhook, dependent: :delete
  end

  module ClassMethods
    def create_bot!(attributes, actor:, current_session: nil)
      attributes = attributes.to_h.symbolize_keys
      bot_token = generate_bot_token
      webhook_url = attributes.delete(:webhook_url)
      avatar = attributes.delete(:avatar)
      current_session_id = current_session&.id
      current_session_token = current_session&.token&.dup

      StagedUpload.with(avatar) do |blob|
        User::MutationFence.with(actor.id) do
          if current_session
            Session.authenticate_exact!(
              id: current_session_id, token: current_session_token, user_id: actor.id
            )
          end
          transaction do
            lock_administrator! actor
            User.create!(**attributes, bot_token: bot_token, role: :bot).tap do |user|
              StagedUpload.attach! user.avatar, blob if blob
              user.create_webhook!(url: webhook_url) if webhook_url.present?
            end
          end
        end
      end
    end

    def authenticate_bot(bot_key)
      bot_id, bot_token = bot_key.split("-")
      active_bots.find_by(id: bot_id, bot_token: bot_token)
    end

    def verify_bot_key!(bot, bot_key)
      expected_key = bot.bot_key if bot.bot?
      valid = expected_key && bot_key && expected_key.bytesize == bot_key.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(expected_key, bot_key)
      raise User::AuthorizationError, "authenticated bot credential was revoked" unless valid

      bot
    end

    def generate_bot_token
      SecureRandom.alphanumeric(12)
    end
  end

  def update_bot!(attributes, actor:, current_session: nil)
    attributes = attributes.to_h.symbolize_keys
    webhook_url_supplied = attributes.key?(:webhook_url)
    webhook_url = attributes.delete(:webhook_url)
    avatar_upload = attributes.delete(:avatar)
    current_session_id = current_session&.id
    current_session_token = current_session&.token&.dup

    StagedUpload.with(avatar_upload) do |blob|
      User::MutationFence.with([ actor.id, id ]) do
        if current_session
          Session.authenticate_exact!(
            id: current_session_id, token: current_session_token, user_id: actor.id
          )
        end
        transaction do
          self.class.lock_administrator! actor
          bot = self.class.active_bots.lock.find(id)
          bot.send :update_webhook_url!, webhook_url if webhook_url_supplied
          bot.update!(attributes)
          StagedUpload.attach! bot.avatar, blob if blob
        end
      end
    end
    self
  end


  def bot_key
    "#{id}-#{bot_token}"
  end

  def reset_bot_key!(actor:)
    User::MutationFence.with(id) do
      transaction do
        self.class.lock_administrator! actor
        self.class.active_bots.lock.find(id).update!(bot_token: self.class.generate_bot_token)
      end
    end
    reload
  end


  def webhook_url
    defined?(@webhook_url) ? @webhook_url : webhook&.url
  end

  def webhook_url=(url)
    @webhook_url = url
  end

  def reload(...)
    super.tap { remove_instance_variable(:@webhook_url) if defined?(@webhook_url) }
  end

  def deliver_webhook_later(message)
    if current_webhook = webhook
      Bot::WebhookJob.perform_later(
        self, message, current_webhook.id, current_webhook.delivery_generation, SecureRandom.uuid
      )
    end
  end

  def deliver_webhook(message, webhook_id:, webhook_generation:, delivery_id:)
    User::MutationFence.with(id) do
      delivery = self.class.transaction do
        current_message = Message.lock.find_by(id: message.id, room_id: message.room_id)
        next unless current_message
        bot = self.class.active_bots.lock.find_by(id:)
        next unless bot && bot.id != current_message.creator_id
        next unless Membership.lock.exists?(room_id: current_message.room_id, user_id: bot.id)
        next unless current_message.room.direct? || current_message.mentionees.exists?(id: bot.id)

        current_webhook = Webhook.lock.find_by(
          id: webhook_id, user_id: bot.id, delivery_generation: webhook_generation
        )
        [ current_webhook, current_message ] if current_webhook
      end
      delivery&.then { |current_webhook, current_message| current_webhook.deliver(current_message, delivery_id:) }
    end
  end


  private
    def update_webhook_url!(url)
      if url.present?
        webhook&.update!(url: url) || create_webhook!(url: url)
      else
        webhook&.destroy
      end
    end
end
