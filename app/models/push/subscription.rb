require "base64"

class Push::Subscription < ApplicationRecord
  MAXIMUM_SUBSCRIPTIONS_PER_USER = 20
  MAXIMUM_KEY_LENGTH = 256
  MAXIMUM_USER_AGENT_LENGTH = 512
  AUTH_KEY_BYTES = 16
  P256DH_KEY_BYTES = 65

  belongs_to :user
  belongs_to :session, optional: true

  validates :endpoint, :p256dh_key, :auth_key, presence: true
  validates :endpoint, length: { maximum: WebPush::Endpoint::MAXIMUM_LENGTH }
  validates :p256dh_key, :auth_key,
    length: { maximum: MAXIMUM_KEY_LENGTH }, format: { with: /\A[A-Za-z0-9_-]+\z/ }
  validates :user_agent, length: { maximum: MAXIMUM_USER_AGENT_LENGTH }, allow_nil: true
  validate :session_belongs_to_user, :endpoint_is_safe, :keys_are_valid
  validate :within_user_quota, if: :quota_must_be_checked?

  scope :with_current_session, -> {
    joins(:session).merge(Session.authenticatable)
      .where("sessions.user_id = push_subscriptions.user_id")
  }

  class << self
    def synchronize!(capability:, user:, session:, user_agent:)
      transaction do
        user.lock!
        current = lock.find_by(session_id: session.id)
        matching = lock.where(capability)
        subscription = matching.find_by(session_id: session.id) || matching.find_by(user:) ||
          matching.order(:id).first || current || new(capability)
        current.delete if current && current.id != subscription.id
        matching.where.not(id: subscription.id).delete_all if subscription.persisted?
        subscription.update!(capability.merge(user:, session:, user_agent:))
        subscription
      end
    end
  end

  def notification(**params)
    WebPush::Notification.new(**params, badge: 0, endpoint: endpoint, p256dh_key: p256dh_key, auth_key: auth_key)
  end

  private
    def session_belongs_to_user
      errors.add :session, "must belong to the subscription user" if session && session.user_id != user_id
    end

    def endpoint_is_safe
      WebPush::Endpoint.parse(endpoint)
    rescue WebPush::Endpoint::Denied => error
      errors.add :endpoint, error.message
    end

    def keys_are_valid
      errors.add :auth_key, "is invalid" unless valid_auth_key?
      errors.add :p256dh_key, "is invalid" unless valid_p256dh_key?
    end

    def valid_auth_key?
      auth_key.blank? || decoded_key(auth_key)&.bytesize == AUTH_KEY_BYTES
    end

    def valid_p256dh_key?
      return true if p256dh_key.blank?

      key = decoded_key(p256dh_key)
      return false unless key&.bytesize == P256DH_KEY_BYTES && key.getbyte(0) == 4

      group = OpenSSL::PKey::EC::Group.new("prime256v1")
      point = OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(key, 2))
      point.on_curve? && !point.infinity?
    rescue OpenSSL::OpenSSLError
      false
    end

    def decoded_key(value)
      Base64.urlsafe_decode64(value).then do |decoded|
        decoded if Base64.urlsafe_encode64(decoded, padding: false) == value
      end
    rescue ArgumentError
      nil
    end

    def quota_must_be_checked?
      new_record? || will_save_change_to_user_id?
    end

    def within_user_quota
      if user && user.push_subscriptions.where.not(id: id).count >= MAXIMUM_SUBSCRIPTIONS_PER_USER
        errors.add :base, "too many Web Push subscriptions"
      end
    end
end
